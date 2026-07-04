local ffi = zune.ffi

export type Connection = { _conn: FFIPointer }
export type ParamValue = string | number | boolean | nil
export type QueryOutcome = {
    ok: boolean,
    rows: { Row }?,
    error: string?,
}

local CONNECTION_OK = 0
local PGRES_COMMAND_OK = 1
local PGRES_TUPLES_OK = 2
local POINTER_SIZE = 8 -- 64-bit target

local lib = ffi.dlopen(`libpq.so.5`, {
    PQconnectdb = { returns = ffi.types.pointer, args = { ffi.types.pointer } },
    PQstatus = { returns = ffi.types.i32, args = { ffi.types.pointer } },
    PQerrorMessage = { returns = ffi.types.pointer, args = { ffi.types.pointer } },
    PQfinish = { returns = ffi.types.void, args = { ffi.types.pointer } },
    PQexec = { returns = ffi.types.pointer, args = { ffi.types.pointer, ffi.types.pointer } },
    PQexecParams = {
        returns = ffi.types.pointer,
        args = {
            ffi.types.pointer, ffi.types.pointer, ffi.types.i32,
            ffi.types.pointer, ffi.types.pointer, ffi.types.pointer,
            ffi.types.pointer, ffi.types.i32,
        },
    },
    PQresultStatus = { returns = ffi.types.i32, args = { ffi.types.pointer } },
    PQresultErrorMessage = { returns = ffi.types.pointer, args = { ffi.types.pointer } },
    PQntuples = { returns = ffi.types.i32, args = { ffi.types.pointer } },
    PQnfields = { returns = ffi.types.i32, args = { ffi.types.pointer } },
    PQfname = { returns = ffi.types.pointer, args = { ffi.types.pointer, ffi.types.i32 } },
    PQgetvalue = { returns = ffi.types.pointer, args = { ffi.types.pointer, ffi.types.i32, ffi.types.i32 } },
    PQgetisnull = { returns = ffi.types.i32, args = { ffi.types.pointer, ffi.types.i32, ffi.types.i32 } },
    PQclear = { returns = ffi.types.void, args = { ffi.types.pointer } },
})

-- ===== internal helpers =====

local function cstr(s: string): buffer
    return buffer.fromstring(s .. "\0")
end

local function readCString(ptr: FFIPointer): string
    local offset = 0
    while ptr:readu8(offset) ~= 0 do
        offset += 1
    end
    ptr:size(offset)
    local buf = ptr:span(0)
    return buffer.readstring(buf, 0, offset)
end

-- Shared by pg.exec and pg.query: turns a PGresult* into our QueryOutcome shape.
-- Always clears the result before returning, so callers never have to remember to.
local function readResult(res: FFIPointer): QueryOutcome
    local status = lib.PQresultStatus(res)

    if status ~= PGRES_TUPLES_OK and status ~= PGRES_COMMAND_OK then
        local err = readCString(lib.PQresultErrorMessage(res))
        lib.PQclear(res)
        return { ok = false, rows = nil, error = err }
    end

    if status == PGRES_COMMAND_OK then
        lib.PQclear(res)
        return { ok = true, rows = {}, error = nil }
    end

    local rowCount = lib.PQntuples(res)
    local colCount = lib.PQnfields(res)

    local colNames = table.create(colCount)
    for c = 0, colCount - 1 do
        colNames[c + 1] = readCString(lib.PQfname(res, c))
    end

    local rows = table.create(rowCount)
    for r = 0, rowCount - 1 do
        local row: Row = {}
        for c = 0, colCount - 1 do
            local isNull = lib.PQgetisnull(res, r, c) == 1
            row[colNames[c + 1]] = if isNull then nil else readCString(lib.PQgetvalue(res, r, c))
        end
        rows[r + 1] = row
    end

    lib.PQclear(res)
    return { ok = true, rows = rows, error = nil }
end

-- nil -> write ffi.null (SQL NULL). Everything else stringifies.
local function paramToBuffer(v: ParamValue): buffer?
    if v == nil then
        return nil
    elseif type(v) == "boolean" then
        return cstr(if v then "true" else "false")
    else
        return cstr(tostring(v))
    end
end

local function buildParamArray(params: { ParamValue }): (FFIPointer, { buffer })
    local n = #params
    local arr = ffi.alloc(POINTER_SIZE * n)
    local keepAlive = {}

    for i, v in params do
        local buf = paramToBuffer(v)
        if buf == nil then
            arr:writeptr((i - 1) * POINTER_SIZE, ffi.null)
        else
            local ptr = ffi.dupe(buf)
            keepAlive[i] = buf
            arr:writeptr((i - 1) * POINTER_SIZE, ptr)
        end
    end

    return arr, keepAlive
end

--[[
    No bind params, uses the simple query protocol — supports multiple
    semicolon-separated statements in one call, unlike PQexecParams.
    Kept private: only for internal use (for future migration runner).
    Public API should always go through pg.query.
]]
local function _execRaw(conn: Connection, sql: string): QueryOutcome
    local res = lib.PQexec(conn._conn, cstr(sql))
    return readResult(res)
end

-- ===== public API =====

local pg = {}
-- create a documentation comment for the public API, and don't forget to include a description

--[[
    Connects to a PostgreSQL database using the provided connection string.

    @param conninfo: The connection string in the format `"postgresql://user:password@host:port/database"`.
    @return `Connection?, string?:` A tuple containing the Connection object and an error message (if any). If the connection is successful, the error message will be nil. If the connection fails, the Connection object will be nil.
]]
function pg.connect(conninfo: string): (Connection?, string?)
    local raw = lib.PQconnectdb(cstr(conninfo))
    local status = lib.PQstatus(raw)

    if status ~= CONNECTION_OK then
        local err = readCString(lib.PQerrorMessage(raw))
        lib.PQfinish(raw)
        return nil, err
    end

    return { _conn = raw }, nil
end

--[[
    Executes an SQL query with optional parameters.

    #### Parameters
    - `conn:` The Connection object representing the database connection.
    - `sql:` The SQL query string to be executed.
    - `params:` An optional table of parameters to be used in the query. Each parameter can be a string, number, boolean, or nil (for SQL NULL).

    #### Returns
    - `QueryOutcome:` A table containing the outcome of the query execution. It includes:
        - `ok:` A boolean indicating whether the query was successful.
        - `rows:` An optional table of rows returned by the query (if any).
        - `error:` An optional error message (if any).
]]
function pg.query(conn: Connection, sql: string, params: { ParamValue }?): QueryOutcome
    local p = params or {}
    local arr, _keepAlive = buildParamArray(p)

    local res = lib.PQexecParams(
        conn._conn,
        cstr(sql),
        #p,
        ffi.null,
        arr,
        ffi.null,
        ffi.null,
        0
    )
    
    local outcome = readResult(res)
    -- keepAlive only needs to survive until here
    return outcome
end

--[[
    Closes the database connection.

    @param conn: The Connection object representing the database connection to be closed.
]]
function pg.close(conn: Connection)
    lib.PQfinish(conn._conn)
end

return pg

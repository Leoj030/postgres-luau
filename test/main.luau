local pg = require("../pg")

local conn, err = pg.connect("postgresql://postgres:postgres@localhost:5432/postgres")

if not conn then
    error(`Connection failed: {err}`)
end

local createResult = pg.query(conn, [[
    CREATE TABLE IF NOT EXISTS users (
        name TEXT NOT NULL, 
        age SMALLINT NOT NULL, 
        bio TEXT
    )
]])

if not createResult.ok then
    error(`Create Failed: {createResult.error}`)
end

local result = pg.query(conn, "INSERT INTO users (name, age, bio) VALUES ($1, $2, $3)",
    { 
        "John Doe", 
        40, 
        "Lorem ipsum dolor sit amet, consectetur adipiscing elit" 
    }
)

if not result.ok then
    error(`insert failed: {result.error}`)
end

print("insert succeeded")

pg.close(conn)


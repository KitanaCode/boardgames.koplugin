local Dispatcher = require("dispatcher") -- luacheck:ignore
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
local Geometry = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local ok_luasettings, LuaSettings = pcall(require, "luasettings")
local logger = require("logger")
local _ = require("gettext")

local function getPluginPath()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    local dir = source:match("(.*/)main%.lua$") or source:match("(.*\\)main%.lua$")
    if dir then
        dir = dir:gsub("\\", "/")
        return dir:sub(-1) == "/" and dir:sub(1, -2) or dir
    end
    return DataStorage:getDataDir() .. "/plugins/boardgames.koplugin"
end

local PLUGIN_PATH = getPluginPath()
if not package.path:find(PLUGIN_PATH, 1, true) then
    package.path = PLUGIN_PATH .. "/?.lua;" .. package.path
end

local ButtonTable = require("buttontable")

local GameHub = WidgetContainer:extend{
    name = "boardgames",
    background = Blitbuffer.COLOR_WHITE,
    bordersize = 0,
    padding = 0,
    margin = 0,
    full_width = Screen:getWidth(),
    full_height = Screen:getHeight(),
    is_doc_only = false,
}

local HUMAN_VS_HUMAN = "2p"
local HUMAN_VS_BOT = "bot"
local CHECKERS = "checkers"
local CHESS = "chess"
local CONNECT4 = "connect4"
local TICTACTOE = "tictactoe"
local MINESWEEPER = "minesweeper"
local BATTLESHIP = "battleship"
local DIFFICULTIES = { "Easy", "Medium", "Hard" }
local BOT_DELAY_SECONDS = 2.35
local CHECKERS_FORCE_CAPTURE = false -- casual mode: captures are optional
local CHECKERS_DRAW_LIMITS = { 40, 60, 80 }
local MINESWEEPER_ROWS = 9
local MINESWEEPER_COLS = 9
local MINESWEEPER_MINE_COUNTS = { 10, 10, 10 }
local BATTLESHIP_ROWS = 10
local BATTLESHIP_COLS = 10
local BATTLESHIP_SHIPS = { 5, 4, 3, 3, 2 }
local BATTLESHIP_SHIP_NAMES = { "Carrier", "Battleship", "Cruiser", "Submarine", "Destroyer" }
local CHESS_PROMOTION_PIECE = "q"
local CHESS_EN_PASSANT = nil
local CHESS_EN_PASSANT_ENABLED = true
local CHESS_CASTLING_ENABLED = true
local CHESS_CASTLING_RIGHTS = nil

local function checked_label(enabled, text)
    return (enabled and "[x] " or "[ ] ") .. text
end

local function fresh_stats()
    return {
        [CHECKERS] = { played = 0, wins = 0, losses = 0, draws = 0, streak = 0, best_streak = 0 },
        [CHESS] = { played = 0, wins = 0, losses = 0, draws = 0, streak = 0, best_streak = 0 },
        [CONNECT4] = { played = 0, wins = 0, losses = 0, draws = 0, streak = 0, best_streak = 0 },
        [TICTACTOE] = { played = 0, wins = 0, losses = 0, draws = 0, streak = 0, best_streak = 0 },
        [MINESWEEPER] = { played = 0, wins = 0, losses = 0, draws = 0, streak = 0, best_streak = 0 },
        [BATTLESHIP] = { played = 0, wins = 0, losses = 0, draws = 0, streak = 0, best_streak = 0 },
    }
end

local function normalize_stats(stats)
    local result = fresh_stats()
    if type(stats) ~= "table" then return result end
    for kind, row in pairs(result) do
        local saved = stats[kind]
        if type(saved) == "table" then
                row.played = tonumber(saved.played) or 0
                row.wins = tonumber(saved.wins) or 0
                row.losses = tonumber(saved.losses) or 0
                row.draws = tonumber(saved.draws) or 0
                row.streak = tonumber(saved.streak) or 0
                row.best_streak = tonumber(saved.best_streak) or 0
            end
        end
    return result
end

local function copy_file(src, dst)
    local input = io.open(src, "rb")
    if not input then return false end
    local data = input:read("*a")
    input:close()
    local output = io.open(dst, "wb")
    if not output then return false end
    output:write(data)
    output:close()
    return true
end

local function ensure_icon_folder(src_subdir, dst_subdir)
    local src_dir = PLUGIN_PATH .. "/icons/" .. src_subdir
    if lfs.attributes(src_dir, "mode") ~= "directory" then return end
    local data_icons_dir = DataStorage:getDataDir() .. "/icons"
    if lfs.attributes(data_icons_dir, "mode") ~= "directory" then lfs.mkdir(data_icons_dir) end
    local dst_dir = data_icons_dir .. "/" .. dst_subdir
    if lfs.attributes(dst_dir, "mode") ~= "directory" then lfs.mkdir(dst_dir) end
    for entry in lfs.dir(src_dir) do
        if entry ~= "." and entry ~= ".." then
            local src_path = src_dir .. "/" .. entry
            if lfs.attributes(src_path, "mode") == "file" then
                copy_file(src_path, dst_dir .. "/" .. entry)
            end
        end
    end
end

local function ensureBoardGameIconsInstalled()
    ensure_icon_folder("chess", "chess")
    ensure_icon_folder("boardgames", "boardgames")
end

local function on_board(r, c)
    return r >= 1 and r <= 8 and c >= 1 and c <= 8
end

local function playable_square(r, c)
    return (r + c) % 2 == 1
end

local function file_letter(c)
    return string.char(string.byte("a") + c - 1)
end

local function internal_to_display_rank(r)
    return 9 - r
end

local function square_name(r, c)
    return string.format("%s%d", file_letter(c), internal_to_display_rank(r))
end

local function side_label(side)
    return side == "w" and "White" or "Black"
end

local function move_label(move)
    return square_name(move.from_r, move.from_c) .. " to " .. square_name(move.to_r, move.to_c)
end

local function fresh_chess_castling_rights()
    return {
        w = { king = true, queen = true },
        b = { king = true, queen = true },
    }
end

local function copy_chess_castling_rights(rights)
    rights = rights or fresh_chess_castling_rights()
    return {
        w = { king = rights.w and rights.w.king ~= false, queen = rights.w and rights.w.queen ~= false },
        b = { king = rights.b and rights.b.king ~= false, queen = rights.b and rights.b.queen ~= false },
    }
end

local function blank_board()
    local board = {}
    for r = 1, 8 do
        board[r] = {}
        for c = 1, 8 do
            board[r][c] = "."
        end
    end
    return board
end

local function clone_board(board)
    local new_board = {}
    for r = 1, #board do
        new_board[r] = {}
        for c = 1, #(board[r] or {}) do
            new_board[r][c] = board[r][c]
        end
    end
    return new_board
end


-- ===== CONNECT 4 =====

local CONNECT4_ROWS = 6
local CONNECT4_COLS = 7

local function fresh_connect4_board()
    local board = {}
    for r = 1, CONNECT4_ROWS do
        board[r] = {}
        for c = 1, CONNECT4_COLS do
            board[r][c] = "."
        end
    end
    return board
end

local function connect4_drop_row(board, col)
    if col < 1 or col > CONNECT4_COLS then return nil end
    for r = CONNECT4_ROWS, 1, -1 do
        if board[r][col] == "." then return r end
    end
    return nil
end

local function connect4_is_full(board)
    for c = 1, CONNECT4_COLS do
        if board[1][c] == "." then return false end
    end
    return true
end

local function connect4_winner(board, piece)
    local dirs = { {0, 1}, {1, 0}, {1, 1}, {1, -1} }
    for r = 1, CONNECT4_ROWS do
        for c = 1, CONNECT4_COLS do
            if board[r][c] == piece then
                for _, d in ipairs(dirs) do
                    local count = 1
                    for step = 1, 3 do
                        local rr = r + d[1] * step
                        local cc = c + d[2] * step
                        if rr >= 1 and rr <= CONNECT4_ROWS and cc >= 1 and cc <= CONNECT4_COLS and board[rr][cc] == piece then
                            count = count + 1
                        else
                            break
                        end
                    end
                    if count >= 4 then return true end
                end
            end
        end
    end
    return false
end

local function connect4_list_moves(board)
    local moves = {}
    for c = 1, CONNECT4_COLS do
        if connect4_drop_row(board, c) then
            moves[#moves + 1] = c
        end
    end
    return moves
end

local function connect4_apply_move_clone(board, col, piece)
    local row = connect4_drop_row(board, col)
    if not row then return nil, nil end
    local new_board = clone_board(board)
    new_board[row][col] = piece
    return new_board, row
end

local function connect4_window_score(window)
    local bot, human, empty = 0, 0, 0
    for _, p in ipairs(window) do
        if p == "b" then bot = bot + 1
        elseif p == "w" then human = human + 1
        else empty = empty + 1 end
    end
    if bot > 0 and human > 0 then return 0 end
    if bot == 4 then return 100000 end
    if human == 4 then return -100000 end
    if bot == 3 and empty == 1 then return 250 end
    if bot == 2 and empty == 2 then return 40 end
    if human == 3 and empty == 1 then return -320 end
    if human == 2 and empty == 2 then return -50 end
    return 0
end

local function connect4_evaluate(board)
    if connect4_winner(board, "b") then return 100000 end
    if connect4_winner(board, "w") then return -100000 end
    local score = 0
    for r = 1, CONNECT4_ROWS do
        if board[r][4] == "b" then score = score + 8 end
        if board[r][4] == "w" then score = score - 8 end
    end
    local dirs = { {0, 1}, {1, 0}, {1, 1}, {1, -1} }
    for r = 1, CONNECT4_ROWS do
        for c = 1, CONNECT4_COLS do
            for _, d in ipairs(dirs) do
                local window = {}
                local ok = true
                for step = 0, 3 do
                    local rr = r + d[1] * step
                    local cc = c + d[2] * step
                    if rr < 1 or rr > CONNECT4_ROWS or cc < 1 or cc > CONNECT4_COLS then
                        ok = false
                        break
                    end
                    window[#window + 1] = board[rr][cc]
                end
                if ok then score = score + connect4_window_score(window) end
            end
        end
    end
    return score
end

local function connect4_minimax(board, turn, depth, alpha, beta)
    if depth <= 0 or connect4_winner(board, "b") or connect4_winner(board, "w") or connect4_is_full(board) then
        return connect4_evaluate(board)
    end
    local moves = connect4_list_moves(board)
    if turn == "b" then
        local best = -1000000
        for _, col in ipairs(moves) do
            local nb = connect4_apply_move_clone(board, col, "b")
            local value = connect4_minimax(nb, "w", depth - 1, alpha, beta)
            if value > best then best = value end
            if value > alpha then alpha = value end
            if beta <= alpha then break end
        end
        return best
    else
        local best = 1000000
        for _, col in ipairs(moves) do
            local nb = connect4_apply_move_clone(board, col, "w")
            local value = connect4_minimax(nb, "b", depth - 1, alpha, beta)
            if value < best then best = value end
            if value < beta then beta = value end
            if beta <= alpha then break end
        end
        return best
    end
end


-- ===== TIC TAC TOE =====

local TTT_ROWS = 3
local TTT_COLS = 3

local function fresh_tictactoe_board()
    local board = {}
    for r = 1, TTT_ROWS do
        board[r] = {}
        for c = 1, TTT_COLS do
            board[r][c] = "."
        end
    end
    return board
end

local function tictactoe_winner(board, piece)
    for r = 1, TTT_ROWS do
        if board[r][1] == piece and board[r][2] == piece and board[r][3] == piece then return true end
    end
    for c = 1, TTT_COLS do
        if board[1][c] == piece and board[2][c] == piece and board[3][c] == piece then return true end
    end
    if board[1][1] == piece and board[2][2] == piece and board[3][3] == piece then return true end
    if board[1][3] == piece and board[2][2] == piece and board[3][1] == piece then return true end
    return false
end

local function tictactoe_is_full(board)
    for r = 1, TTT_ROWS do
        for c = 1, TTT_COLS do
            if board[r][c] == "." then return false end
        end
    end
    return true
end

local function tictactoe_list_moves(board)
    local moves = {}
    for r = 1, TTT_ROWS do
        for c = 1, TTT_COLS do
            if board[r][c] == "." then
                moves[#moves + 1] = { r = r, c = c }
            end
        end
    end
    return moves
end

local function tictactoe_apply_move_clone(board, r, c, piece)
    if r < 1 or r > TTT_ROWS or c < 1 or c > TTT_COLS or board[r][c] ~= "." then
        return nil
    end
    local new_board = clone_board(board)
    new_board[r][c] = piece
    return new_board
end

local function tictactoe_score_terminal(board, depth)
    if tictactoe_winner(board, "b") then return 10 + depth end
    if tictactoe_winner(board, "w") then return -10 - depth end
    return 0
end

-- ===== MINESWEEPER =====

local minesweeper_seed_mines

local function fresh_bool_grid(rows, cols, value)
    local grid = {}
    for r = 1, rows do
        grid[r] = {}
        for c = 1, cols do
            grid[r][c] = value == true
        end
    end
    return grid
end

local function copy_bool_grid(grid, rows, cols)
    if not grid then return fresh_bool_grid(rows, cols, false) end
    local copy = {}
    for r = 1, rows do
        copy[r] = {}
        for c = 1, cols do
            copy[r][c] = grid[r] and grid[r][c] == true or false
        end
    end
    return copy
end

local function fresh_minesweeper_state(mine_count)
    local state = {
        rows = MINESWEEPER_ROWS,
        cols = MINESWEEPER_COLS,
        mines = mine_count or MINESWEEPER_MINE_COUNTS[2],
        revealed = fresh_bool_grid(MINESWEEPER_ROWS, MINESWEEPER_COLS, false),
        flagged = fresh_bool_grid(MINESWEEPER_ROWS, MINESWEEPER_COLS, false),
        mined = fresh_bool_grid(MINESWEEPER_ROWS, MINESWEEPER_COLS, false),
        generated = true,
        first_reveal_done = false,
        revealed_count = 0,
        flags = 0,
    }
    minesweeper_seed_mines(state)
    return state
end

local function copy_minesweeper_state(state)
    if not state then return nil end
    local rows = state.rows or MINESWEEPER_ROWS
    local cols = state.cols or MINESWEEPER_COLS
    return {
        rows = rows,
        cols = cols,
        mines = state.mines or MINESWEEPER_MINE_COUNTS[2],
        revealed = copy_bool_grid(state.revealed, rows, cols),
        flagged = copy_bool_grid(state.flagged, rows, cols),
        mined = copy_bool_grid(state.mined, rows, cols),
        generated = state.generated == true,
        first_reveal_done = state.first_reveal_done == true,
        revealed_count = state.revealed_count or 0,
        flags = state.flags or 0,
    }
end

local function minesweeper_each_neighbor(state, r, c, callback)
    for dr = -1, 1 do
        for dc = -1, 1 do
            if dr ~= 0 or dc ~= 0 then
                local nr, nc = r + dr, c + dc
                if nr >= 1 and nr <= state.rows and nc >= 1 and nc <= state.cols then
                    callback(nr, nc)
                end
            end
        end
    end
end

local function minesweeper_adjacent_count(state, r, c)
    local count = 0
    minesweeper_each_neighbor(state, r, c, function(nr, nc)
        if state.mined[nr][nc] then count = count + 1 end
    end)
    return count
end

local function minesweeper_mine_count(state)
    local count = 0
    if not state then return count end
    for r = 1, state.rows do
        for c = 1, state.cols do
            if state.mined[r][c] then count = count + 1 end
        end
    end
    return count
end

local function minesweeper_in_safe_zone(r, c, safe_r, safe_c)
    return safe_r and safe_c and math.abs(r - safe_r) <= 1 and math.abs(c - safe_c) <= 1
end

minesweeper_seed_mines = function(state, safe_r, safe_c)
    state.mined = fresh_bool_grid(state.rows, state.cols, false)
    local choices = {}
    for r = 1, state.rows do
        for c = 1, state.cols do
            if not minesweeper_in_safe_zone(r, c, safe_r, safe_c) then
                choices[#choices + 1] = { r = r, c = c }
            end
        end
    end
    for i = #choices, 2, -1 do
        local j = math.random(i)
        choices[i], choices[j] = choices[j], choices[i]
    end
    for i = 1, math.min(state.mines, #choices) do
        local cell = choices[i]
        state.mined[cell.r][cell.c] = true
    end
    state.generated = true
end

local function minesweeper_protect_first_reveal(state, safe_r, safe_c)
    if state.first_reveal_done then return end
    if minesweeper_mine_count(state) ~= (state.mines or 0) then
        minesweeper_seed_mines(state, safe_r, safe_c)
        state.first_reveal_done = true
        return
    end

    local moved = 0
    for r = 1, state.rows do
        for c = 1, state.cols do
            if minesweeper_in_safe_zone(r, c, safe_r, safe_c) and state.mined[r][c] then
                state.mined[r][c] = false
                moved = moved + 1
            end
        end
    end

    if moved > 0 then
        local choices = {}
        for r = 1, state.rows do
            for c = 1, state.cols do
                if not minesweeper_in_safe_zone(r, c, safe_r, safe_c) and not state.mined[r][c] then
                    choices[#choices + 1] = { r = r, c = c }
                end
            end
        end
        for i = #choices, 2, -1 do
            local j = math.random(i)
            choices[i], choices[j] = choices[j], choices[i]
        end
        for i = 1, math.min(moved, #choices) do
            local cell = choices[i]
            state.mined[cell.r][cell.c] = true
        end
    end
    state.first_reveal_done = true
    state.generated = true
end

local function minesweeper_reveal_cell(state, r, c)
    if state.revealed[r][c] or state.flagged[r][c] then return 0 end
    local revealed = 0
    local queue = { { r = r, c = c } }
    local head = 1
    while head <= #queue do
        local cell = queue[head]
        head = head + 1
        local cr, cc = cell.r, cell.c
        if not state.revealed[cr][cc] and not state.flagged[cr][cc] then
            state.revealed[cr][cc] = true
            revealed = revealed + 1
            if minesweeper_adjacent_count(state, cr, cc) == 0 then
                minesweeper_each_neighbor(state, cr, cc, function(nr, nc)
                    if not state.revealed[nr][nc] and not state.flagged[nr][nc] and not state.mined[nr][nc] then
                        queue[#queue + 1] = { r = nr, c = nc }
                    end
                end)
            end
        end
    end
    state.revealed_count = (state.revealed_count or 0) + revealed
    return revealed
end

-- ===== BATTLESHIP =====

local function fresh_battleship_shot_grid()
    return fresh_bool_grid(BATTLESHIP_ROWS, BATTLESHIP_COLS, false)
end

local function fresh_battleship_ship_grid()
    return fresh_bool_grid(BATTLESHIP_ROWS, BATTLESHIP_COLS, false)
end

local function fresh_battleship_id_grid()
    local grid = {}
    for r = 1, BATTLESHIP_ROWS do
        grid[r] = {}
        for c = 1, BATTLESHIP_COLS do
            grid[r][c] = 0
        end
    end
    return grid
end

local function copy_battleship_id_grid(grid)
    local copy = fresh_battleship_id_grid()
    if not grid then return copy end
    for r = 1, BATTLESHIP_ROWS do
        for c = 1, BATTLESHIP_COLS do
            copy[r][c] = grid[r] and tonumber(grid[r][c]) or 0
        end
    end
    return copy
end

local function copy_array_table(values)
    local copy = {}
    if not values then return copy end
    for k, v in pairs(values) do
        copy[k] = v
    end
    return copy
end

local function battleship_can_place(grid, r, c, length, horizontal)
    local end_r = horizontal and r or r + length - 1
    local end_c = horizontal and c + length - 1 or c
    if end_r > BATTLESHIP_ROWS or end_c > BATTLESHIP_COLS then return false end
    for i = 0, length - 1 do
        local rr = horizontal and r or r + i
        local cc = horizontal and c + i or c
        if grid[rr][cc] then return false end
    end
    return true
end

local function battleship_place_ship(grid, ids, id, r, c, length, horizontal)
    for i = 0, length - 1 do
        local rr = horizontal and r or r + i
        local cc = horizontal and c + i or c
        grid[rr][cc] = true
        ids[rr][cc] = id
    end
end

local function battleship_random_fleet()
    local grid = fresh_battleship_ship_grid()
    local ids = fresh_battleship_id_grid()
    local lengths = {}
    for id, length in ipairs(BATTLESHIP_SHIPS) do
        local placed = false
        for _ = 1, 200 do
            local horizontal = math.random(2) == 1
            local r = math.random(BATTLESHIP_ROWS)
            local c = math.random(BATTLESHIP_COLS)
            if battleship_can_place(grid, r, c, length, horizontal) then
                battleship_place_ship(grid, ids, id, r, c, length, horizontal)
                lengths[id] = length
                placed = true
                break
            end
        end
        if not placed then
            return battleship_random_fleet()
        end
    end
    return grid, ids, lengths
end

local function battleship_ship_cell_count()
    local count = 0
    for _, length in ipairs(BATTLESHIP_SHIPS) do
        count = count + length
    end
    return count
end

local function fresh_battleship_state()
    local bot_ships, bot_ids, bot_lengths = battleship_random_fleet()
    return {
        rows = BATTLESHIP_ROWS,
        cols = BATTLESHIP_COLS,
        player_ships = fresh_battleship_ship_grid(),
        player_ship_ids = fresh_battleship_id_grid(),
        player_ship_lengths = copy_array_table(BATTLESHIP_SHIPS),
        player_sunk = {},
        bot_ships = bot_ships,
        bot_ship_ids = bot_ids,
        bot_ship_lengths = bot_lengths,
        bot_sunk = {},
        player_shots = fresh_battleship_shot_grid(),
        bot_shots = fresh_battleship_shot_grid(),
        player_hits = 0,
        bot_hits = 0,
        total_ship_cells = battleship_ship_cell_count(),
        view = "fleet",
        phase = "setup",
        placing_ship = 1,
        place_horizontal = true,
    }
end

local function copy_battleship_state(state)
    if not state then return nil end
    return {
        rows = state.rows or BATTLESHIP_ROWS,
        cols = state.cols or BATTLESHIP_COLS,
        player_ships = copy_bool_grid(state.player_ships, BATTLESHIP_ROWS, BATTLESHIP_COLS),
        player_ship_ids = copy_battleship_id_grid(state.player_ship_ids),
        player_ship_lengths = copy_array_table(state.player_ship_lengths or BATTLESHIP_SHIPS),
        player_sunk = copy_array_table(state.player_sunk),
        bot_ships = copy_bool_grid(state.bot_ships, BATTLESHIP_ROWS, BATTLESHIP_COLS),
        bot_ship_ids = copy_battleship_id_grid(state.bot_ship_ids),
        bot_ship_lengths = copy_array_table(state.bot_ship_lengths or BATTLESHIP_SHIPS),
        bot_sunk = copy_array_table(state.bot_sunk),
        player_shots = copy_bool_grid(state.player_shots, BATTLESHIP_ROWS, BATTLESHIP_COLS),
        bot_shots = copy_bool_grid(state.bot_shots, BATTLESHIP_ROWS, BATTLESHIP_COLS),
        player_hits = state.player_hits or 0,
        bot_hits = state.bot_hits or 0,
        total_ship_cells = state.total_ship_cells or battleship_ship_cell_count(),
        view = state.view or "enemy",
        phase = state.phase or "battle",
        placing_ship = state.placing_ship or 1,
        place_horizontal = state.place_horizontal ~= false,
    }
end

local function battleship_ship_name(ship_id)
    return BATTLESHIP_SHIP_NAMES[ship_id] or "ship"
end

local function battleship_ship_mark(ship_id)
    local marks = { "A", "B", "C", "S", "D" }
    return marks[ship_id] or "S"
end

local function battleship_is_ship_sunk(ship_ids, shots, ship_id)
    if not ship_id or ship_id == 0 then return false end
    for r = 1, BATTLESHIP_ROWS do
        for c = 1, BATTLESHIP_COLS do
            if ship_ids[r][c] == ship_id and not shots[r][c] then
                return false
            end
        end
    end
    return true
end

local function battleship_sunk_count(sunk)
    local count = 0
    sunk = sunk or {}
    for id = 1, #BATTLESHIP_SHIPS do
        if sunk[id] then count = count + 1 end
    end
    return count
end

local function battleship_random_unshot(shots)
    local choices = {}
    for r = 1, BATTLESHIP_ROWS do
        for c = 1, BATTLESHIP_COLS do
            if not shots[r][c] then
                choices[#choices + 1] = { r = r, c = c }
            end
        end
    end
    if #choices == 0 then return nil end
    return choices[math.random(#choices)]
end

local function battleship_line_target(state)
    state.player_sunk = state.player_sunk or {}
    local choices = {}
    local dirs = { { 1, 0 }, { 0, 1 } }
    for r = 1, BATTLESHIP_ROWS do
        for c = 1, BATTLESHIP_COLS do
            local ship_id = state.player_ship_ids and state.player_ship_ids[r][c] or 0
            if state.bot_shots[r][c] and state.player_ships[r][c] and not state.player_sunk[ship_id] then
                for _, dir in ipairs(dirs) do
                    local nr, nc = r + dir[1], c + dir[2]
                    local next_id = state.player_ship_ids and state.player_ship_ids[nr] and state.player_ship_ids[nr][nc] or 0
                    if nr >= 1 and nr <= BATTLESHIP_ROWS and nc >= 1 and nc <= BATTLESHIP_COLS and
                            state.bot_shots[nr][nc] and state.player_ships[nr][nc] and next_id == ship_id then
                        local br, bc = r - dir[1], c - dir[2]
                        if br >= 1 and br <= BATTLESHIP_ROWS and bc >= 1 and bc <= BATTLESHIP_COLS and not state.bot_shots[br][bc] then
                            choices[#choices + 1] = { r = br, c = bc }
                        end
                        local fr, fc = nr + dir[1], nc + dir[2]
                        while fr >= 1 and fr <= BATTLESHIP_ROWS and fc >= 1 and fc <= BATTLESHIP_COLS and
                                state.bot_shots[fr][fc] and state.player_ships[fr][fc] and
                                state.player_ship_ids[fr][fc] == ship_id do
                            fr, fc = fr + dir[1], fc + dir[2]
                        end
                        if fr >= 1 and fr <= BATTLESHIP_ROWS and fc >= 1 and fc <= BATTLESHIP_COLS and not state.bot_shots[fr][fc] then
                            choices[#choices + 1] = { r = fr, c = fc }
                        end
                    end
                end
            end
        end
    end
    if #choices == 0 then return nil end
    return choices[math.random(#choices)]
end

local function battleship_hunt_target(state)
    state.player_sunk = state.player_sunk or {}
    local choices = {}
    local dirs = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
    for r = 1, BATTLESHIP_ROWS do
        for c = 1, BATTLESHIP_COLS do
            local ship_id = state.player_ship_ids and state.player_ship_ids[r][c] or 0
            if state.bot_shots[r][c] and state.player_ships[r][c] and not state.player_sunk[ship_id] then
                for _, dir in ipairs(dirs) do
                    local nr, nc = r + dir[1], c + dir[2]
                    if nr >= 1 and nr <= BATTLESHIP_ROWS and nc >= 1 and nc <= BATTLESHIP_COLS and not state.bot_shots[nr][nc] then
                        choices[#choices + 1] = { r = nr, c = nc }
                    end
                end
            end
        end
    end
    if #choices == 0 then return nil end
    return choices[math.random(#choices)]
end

local function tictactoe_minimax(board, turn, depth)
    if tictactoe_winner(board, "b") or tictactoe_winner(board, "w") or tictactoe_is_full(board) then
        return tictactoe_score_terminal(board, depth)
    end

    local moves = tictactoe_list_moves(board)
    if turn == "b" then
        local best = -1000000
        for _, move in ipairs(moves) do
            local nb = tictactoe_apply_move_clone(board, move.r, move.c, "b")
            local value = tictactoe_minimax(nb, "w", depth + 1)
            if value > best then best = value end
        end
        return best
    else
        local best = 1000000
        for _, move in ipairs(moves) do
            local nb = tictactoe_apply_move_clone(board, move.r, move.c, "w")
            local value = tictactoe_minimax(nb, "b", depth + 1)
            if value < best then best = value end
        end
        return best
    end
end

local function tictactoe_preferred_moves(moves)
    local order = { {2, 2}, {1, 1}, {1, 3}, {3, 1}, {3, 3}, {1, 2}, {2, 1}, {2, 3}, {3, 2} }
    local result = {}
    for _, want in ipairs(order) do
        for _, move in ipairs(moves) do
            if move.r == want[1] and move.c == want[2] then
                result[#result + 1] = move
                break
            end
        end
    end
    return result
end

-- ===== CHECKERS =====

local function fresh_checkers_board()
    local board = blank_board()
    for r = 1, 3 do
        for c = 1, 8 do
            if playable_square(r, c) then
                board[r][c] = "b"
            end
        end
    end
    for r = 6, 8 do
        for c = 1, 8 do
            if playable_square(r, c) then
                board[r][c] = "w"
            end
        end
    end
    return board
end

local function checkers_owner(piece)
    if piece == "." then return nil end
    return piece:lower()
end

local function checkers_is_king(piece)
    return piece == "W" or piece == "B"
end

local function checkers_is_enemy(piece_a, piece_b)
    return piece_a ~= "." and piece_b ~= "." and checkers_owner(piece_a) ~= checkers_owner(piece_b)
end

local function checkers_step_directions(piece)
    if piece == "w" then return { {-1, -1}, {-1, 1} } end
    if piece == "b" then return { {1, -1}, {1, 1} } end
    return { {-1, -1}, {-1, 1}, {1, -1}, {1, 1} }
end

local function checkers_count_pieces(board)
    local white, black = 0, 0
    for r = 1, 8 do
        for c = 1, 8 do
            local p = board[r][c]
            if checkers_owner(p) == "w" then white = white + 1 end
            if checkers_owner(p) == "b" then black = black + 1 end
        end
    end
    return white, black
end

local function checkers_only_two_kings_left(board)
    local white, black = 0, 0
    local white_king, black_king = false, false
    for r = 1, 8 do
        for c = 1, 8 do
            local p = board[r][c]
            if p == "w" then return false end
            if p == "b" then return false end
            if p == "W" then white = white + 1; white_king = true end
            if p == "B" then black = black + 1; black_king = true end
        end
    end
    return white == 1 and black == 1 and white_king and black_king
end


local function checkers_piece_has_capture(board, r, c)
    local piece = board[r][c]
    if piece == "." then return false end
    for _, dir in ipairs(checkers_step_directions(piece)) do
        local mr, mc = r + dir[1], c + dir[2]
        local tr, tc = r + dir[1] * 2, c + dir[2] * 2
        if on_board(tr, tc) and board[tr][tc] == "." and checkers_is_enemy(piece, board[mr][mc]) then
            return true
        end
    end
    return false
end

local function checkers_piece_has_simple_move(board, r, c)
    local piece = board[r][c]
    if piece == "." then return false end
    for _, dir in ipairs(checkers_step_directions(piece)) do
        local tr, tc = r + dir[1], c + dir[2]
        if on_board(tr, tc) and board[tr][tc] == "." then
            return true
        end
    end
    return false
end

local function checkers_any_capture_for_turn(board, turn)
    for r = 1, 8 do
        for c = 1, 8 do
            if checkers_owner(board[r][c]) == turn and checkers_piece_has_capture(board, r, c) then
                return true
            end
        end
    end
    return false
end

local function checkers_any_move_for_turn(board, turn)
    for r = 1, 8 do
        for c = 1, 8 do
            if checkers_owner(board[r][c]) == turn then
                if checkers_piece_has_capture(board, r, c) or checkers_piece_has_simple_move(board, r, c) then
                    return true
                end
            end
        end
    end
    return false
end

local function checkers_apply_step_clone(board, r1, c1, r2, c2, is_capture, capr, capc)
    local new_board = clone_board(board)
    local piece = new_board[r1][c1]
    new_board[r1][c1] = "."
    if is_capture and capr and capc then
        new_board[capr][capc] = "."
    end
    local promoted = false
    if piece == "w" and r2 == 1 then
        piece = "W"
        promoted = true
    elseif piece == "b" and r2 == 8 then
        piece = "B"
        promoted = true
    end
    new_board[r2][c2] = piece
    return new_board, promoted
end

local function checkers_validate_move(board, turn, r1, c1, r2, c2, forced_from)
    if not (on_board(r1, c1) and on_board(r2, c2)) then
        return false, "Move is off the board."
    end
    if forced_from and (r1 ~= forced_from[1] or c1 ~= forced_from[2]) then
        return false, "Continue jumping from " .. square_name(forced_from[1], forced_from[2]) .. "."
    end
    local piece = board[r1][c1]
    if piece == "." then
        return false, "There is no piece on " .. square_name(r1, c1) .. "."
    end
    if checkers_owner(piece) ~= turn then
        return false, "That is not your piece."
    end
    if board[r2][c2] ~= "." then
        return false, "That square is occupied."
    end
    if not playable_square(r2, c2) then
        return false, "Only dark squares are playable."
    end

    local dr = r2 - r1
    local dc = c2 - c1
    if math.abs(dr) ~= math.abs(dc) then
        return false, "Move diagonally."
    end

    local capture_required = forced_from ~= nil or (CHECKERS_FORCE_CAPTURE and checkers_any_capture_for_turn(board, turn))
    local forward_ok = checkers_is_king(piece)
        or (turn == "w" and dr < 0)
        or (turn == "b" and dr > 0)

    if math.abs(dr) == 1 then
        if capture_required then
            return false, "A capture is required."
        end
        if not forward_ok then
            return false, turn == "w" and "White moves upward." or "Black moves downward."
        end
        return true, false
    elseif math.abs(dr) == 2 then
        if not forward_ok then
            return false, turn == "w" and "White jumps upward." or "Black jumps downward."
        end
        local mr, mc = r1 + dr / 2, c1 + dc / 2
        if not checkers_is_enemy(piece, board[mr][mc]) then
            return false, "Jump over an enemy piece."
        end
        return true, true, mr, mc
    end

    return false, "Move one square, or jump two."
end

local function checkers_destination_set(board, turn, r, c, forced_from)
    local result = {}
    local piece = board[r][c]
    if checkers_owner(piece) ~= turn then return result end
    if forced_from and (r ~= forced_from[1] or c ~= forced_from[2]) then return result end
    local capture_required = forced_from ~= nil or (CHECKERS_FORCE_CAPTURE and checkers_any_capture_for_turn(board, turn))
    for _, dir in ipairs(checkers_step_directions(piece)) do
        local tr1, tc1 = r + dir[1], c + dir[2]
        local tr2, tc2 = r + dir[1] * 2, c + dir[2] * 2
        local can_capture = on_board(tr2, tc2) and board[tr2][tc2] == "." and checkers_is_enemy(piece, board[r + dir[1]][c + dir[2]])
        if can_capture then
            result[tr2 .. ":" .. tc2] = true
        end
        if not capture_required then
            if on_board(tr1, tc1) and board[tr1][tc1] == "." then
                result[tr1 .. ":" .. tc1] = true
            end
        end
    end
    return result
end

local function checkers_list_legal_moves(board, turn)
    local moves = {}
    local capture_required = checkers_any_capture_for_turn(board, turn)

    local function add_capture_sequences(board_state, start_r, start_c, cur_r, cur_c)
        local piece = board_state[cur_r][cur_c]
        local found = false
        for _, dir in ipairs(checkers_step_directions(piece)) do
            local mr, mc = cur_r + dir[1], cur_c + dir[2]
            local tr, tc = cur_r + dir[1] * 2, cur_c + dir[2] * 2
            if on_board(tr, tc) and board_state[tr][tc] == "." and checkers_is_enemy(piece, board_state[mr][mc]) then
                found = true
                local next_board, promoted = checkers_apply_step_clone(board_state, cur_r, cur_c, tr, tc, true, mr, mc)
                if promoted then
                    moves[#moves + 1] = {
                        from_r = start_r, from_c = start_c,
                        to_r = tr, to_c = tc,
                        board = next_board, is_capture = true,
                    }
                else
                    add_capture_sequences(next_board, start_r, start_c, tr, tc)
                end
            end
        end
        if not found and (cur_r ~= start_r or cur_c ~= start_c) then
            moves[#moves + 1] = {
                from_r = start_r, from_c = start_c,
                to_r = cur_r, to_c = cur_c,
                board = board_state, is_capture = true,
            }
        end
    end

    for r = 1, 8 do
        for c = 1, 8 do
            local piece = board[r][c]
            if checkers_owner(piece) == turn then
                if capture_required then
                    if checkers_piece_has_capture(board, r, c) then
                        add_capture_sequences(board, r, c, r, c)
                    end
                else
                    for _, dir in ipairs(checkers_step_directions(piece)) do
                        local tr, tc = r + dir[1], c + dir[2]
                        if on_board(tr, tc) and board[tr][tc] == "." then
                            local next_board = checkers_apply_step_clone(board, r, c, tr, tc, false)
                            moves[#moves + 1] = {
                                from_r = r, from_c = c,
                                to_r = tr, to_c = tc,
                                board = next_board, is_capture = false,
                            }
                        end
                    end
                end
            end
        end
    end

    return moves
end

local function checkers_evaluate_board(board)
    local score = 0
    local white_mobility = #checkers_list_legal_moves(board, "w")
    local black_mobility = #checkers_list_legal_moves(board, "b")
    for r = 1, 8 do
        for c = 1, 8 do
            local p = board[r][c]
            if p == "w" then score = score - 100 - (8 - r) * 2 end
            if p == "W" then score = score - 180 end
            if p == "b" then score = score + 100 + (r - 1) * 2 end
            if p == "B" then score = score + 180 end
            if p ~= "." and r >= 3 and r <= 6 and c >= 3 and c <= 6 then
                if checkers_owner(p) == "b" then score = score + 3 end
                if checkers_owner(p) == "w" then score = score - 3 end
            end
        end
    end
    score = score + (black_mobility - white_mobility) * 4
    return score
end

local function checkers_minimax(board, turn, depth, alpha, beta)
    local moves = checkers_list_legal_moves(board, turn)
    if #moves == 0 then
        if turn == "b" then return -100000 end
        return 100000
    end
    if depth <= 0 then return checkers_evaluate_board(board) end

    if turn == "b" then
        local best = -1000000
        for _, move in ipairs(moves) do
            local value = checkers_minimax(move.board, "w", depth - 1, alpha, beta)
            if value > best then best = value end
            if value > alpha then alpha = value end
            if beta <= alpha then break end
        end
        return best
    else
        local best = 1000000
        for _, move in ipairs(moves) do
            local value = checkers_minimax(move.board, "b", depth - 1, alpha, beta)
            if value < best then best = value end
            if value < beta then beta = value end
            if beta <= alpha then break end
        end
        return best
    end
end

-- ===== CHESS =====

local function fresh_chess_board()
    return {
        {"r", "n", "b", "q", "k", "b", "n", "r"},
        {"p", "p", "p", "p", "p", "p", "p", "p"},
        {".", ".", ".", ".", ".", ".", ".", "."},
        {".", ".", ".", ".", ".", ".", ".", "."},
        {".", ".", ".", ".", ".", ".", ".", "."},
        {".", ".", ".", ".", ".", ".", ".", "."},
        {"P", "P", "P", "P", "P", "P", "P", "P"},
        {"R", "N", "B", "Q", "K", "B", "N", "R"},
    }
end

local function chess_owner(piece)
    if piece == "." then return nil end
    if piece:match("%u") then return "w" end
    return "b"
end

local function chess_is_enemy(piece_a, piece_b)
    return piece_a ~= "." and piece_b ~= "." and chess_owner(piece_a) ~= chess_owner(piece_b)
end

local function chess_is_in_check(board, turn)
    local king = turn == "w" and "K" or "k"
    local kr, kc = nil, nil
    for r = 1, 8 do
        for c = 1, 8 do
            if board[r][c] == king then
                kr, kc = r, c
                break
            end
        end
        if kr then break end
    end
    if not kr then return true end

    -- Pawn attacks
    if turn == "w" then
        for _, dc in ipairs({-1, 1}) do
            local rr, cc = kr - 1, kc + dc
            if on_board(rr, cc) and board[rr][cc] == "p" then return true end
        end
    else
        for _, dc in ipairs({-1, 1}) do
            local rr, cc = kr + 1, kc + dc
            if on_board(rr, cc) and board[rr][cc] == "P" then return true end
        end
    end

    -- Knight attacks
    local knight = turn == "w" and "n" or "N"
    local knight_jumps = {{-2,-1},{-2,1},{-1,-2},{-1,2},{1,-2},{1,2},{2,-1},{2,1}}
    for _, d in ipairs(knight_jumps) do
        local rr, cc = kr + d[1], kc + d[2]
        if on_board(rr, cc) and board[rr][cc] == knight then return true end
    end

    -- Rook/queen lines
    local rook = turn == "w" and "r" or "R"
    local queen = turn == "w" and "q" or "Q"
    for _, d in ipairs({{-1,0},{1,0},{0,-1},{0,1}}) do
        local rr, cc = kr + d[1], kc + d[2]
        while on_board(rr, cc) do
            local p = board[rr][cc]
            if p ~= "." then
                if p == rook or p == queen then return true end
                break
            end
            rr, cc = rr + d[1], cc + d[2]
        end
    end

    -- Bishop/queen lines
    local bishop = turn == "w" and "b" or "B"
    for _, d in ipairs({{-1,-1},{-1,1},{1,-1},{1,1}}) do
        local rr, cc = kr + d[1], kc + d[2]
        while on_board(rr, cc) do
            local p = board[rr][cc]
            if p ~= "." then
                if p == bishop or p == queen then return true end
                break
            end
            rr, cc = rr + d[1], cc + d[2]
        end
    end

    -- King adjacency
    local enemy_king = turn == "w" and "k" or "K"
    for _, d in ipairs({{-1,-1},{-1,0},{-1,1},{0,-1},{0,1},{1,-1},{1,0},{1,1}}) do
        local rr, cc = kr + d[1], kc + d[2]
        if on_board(rr, cc) and board[rr][cc] == enemy_king then return true end
    end

    return false
end

local function chess_pseudo_moves_for_piece(board, turn, r, c)
    local piece = board[r][c]
    local moves = {}
    if piece == "." or chess_owner(piece) ~= turn then return moves end
    local lower = piece:lower()

    local function add_move(rr, cc, extra)
        local move = { from_r = r, from_c = c, to_r = rr, to_c = cc }
        if extra then
            for k, v in pairs(extra) do move[k] = v end
        end
        moves[#moves + 1] = move
    end

    local function king_step_is_safe(rr, cc)
        local next_board = clone_board(board)
        next_board[r][c] = "."
        next_board[rr][cc] = piece
        return not chess_is_in_check(next_board, turn)
    end

    if lower == "p" then
        local dir = turn == "w" and -1 or 1
        local start_row = turn == "w" and 7 or 2
        local rr = r + dir
        if on_board(rr, c) and board[rr][c] == "." then
            add_move(rr, c)
            local rr2 = r + dir * 2
            if r == start_row and on_board(rr2, c) and board[rr2][c] == "." then
                add_move(rr2, c, { double_pawn = true })
            end
        end
        for _, dc in ipairs({-1, 1}) do
            local cc = c + dc
            if on_board(rr, cc) and chess_is_enemy(piece, board[rr][cc]) then
                add_move(rr, cc)
            end
        end
        if CHESS_EN_PASSANT_ENABLED and CHESS_EN_PASSANT and CHESS_EN_PASSANT.turn ~= turn then
            if rr == CHESS_EN_PASSANT.target_r and math.abs(c - CHESS_EN_PASSANT.target_c) == 1 then
                add_move(CHESS_EN_PASSANT.target_r, CHESS_EN_PASSANT.target_c, {
                    en_passant_capture_r = CHESS_EN_PASSANT.capture_r,
                    en_passant_capture_c = CHESS_EN_PASSANT.capture_c,
                })
            end
        end
    elseif lower == "n" then
        for _, d in ipairs({{-2,-1},{-2,1},{-1,-2},{-1,2},{1,-2},{1,2},{2,-1},{2,1}}) do
            local rr, cc = r + d[1], c + d[2]
            if on_board(rr, cc) and chess_owner(board[rr][cc]) ~= turn then
                add_move(rr, cc)
            end
        end
    elseif lower == "b" or lower == "r" or lower == "q" then
        local dirs = {}
        if lower == "b" or lower == "q" then
            dirs[#dirs + 1] = {-1,-1}; dirs[#dirs + 1] = {-1,1}; dirs[#dirs + 1] = {1,-1}; dirs[#dirs + 1] = {1,1}
        end
        if lower == "r" or lower == "q" then
            dirs[#dirs + 1] = {-1,0}; dirs[#dirs + 1] = {1,0}; dirs[#dirs + 1] = {0,-1}; dirs[#dirs + 1] = {0,1}
        end
        for _, d in ipairs(dirs) do
            local rr, cc = r + d[1], c + d[2]
            while on_board(rr, cc) do
                if board[rr][cc] == "." then
                    add_move(rr, cc)
                else
                    if chess_owner(board[rr][cc]) ~= turn then add_move(rr, cc) end
                    break
                end
                rr, cc = rr + d[1], cc + d[2]
            end
        end
    elseif lower == "k" then
        for _, d in ipairs({{-1,-1},{-1,0},{-1,1},{0,-1},{0,1},{1,-1},{1,0},{1,1}}) do
            local rr, cc = r + d[1], c + d[2]
            if on_board(rr, cc) and chess_owner(board[rr][cc]) ~= turn then
                add_move(rr, cc)
            end
        end

        -- Castling requires the original king/rook rights plus clear, safe path squares.
        local home = turn == "w" and 8 or 1
        local king_piece = turn == "w" and "K" or "k"
        local rook_piece = turn == "w" and "R" or "r"
        local rights = CHESS_CASTLING_RIGHTS or fresh_chess_castling_rights()
        local turn_rights = rights[turn] or {}
        if CHESS_CASTLING_ENABLED and r == home and c == 5 and board[r][c] == king_piece and not chess_is_in_check(board, turn) then
            if turn_rights.king ~= false and board[home][8] == rook_piece and board[home][6] == "." and board[home][7] == "." then
                if king_step_is_safe(home, 6) and king_step_is_safe(home, 7) then
                    add_move(home, 7, { castle = "king" })
                end
            end
            if turn_rights.queen ~= false and board[home][1] == rook_piece and board[home][2] == "." and board[home][3] == "." and board[home][4] == "." then
                if king_step_is_safe(home, 4) and king_step_is_safe(home, 3) then
                    add_move(home, 3, { castle = "queen" })
                end
            end
        end
    end

    return moves
end

local function chess_apply_move_clone(board, move)
    local new_board = clone_board(board)
    local piece = new_board[move.from_r][move.from_c]
    new_board[move.from_r][move.from_c] = "."

    if move.en_passant_capture_r and move.en_passant_capture_c then
        new_board[move.en_passant_capture_r][move.en_passant_capture_c] = "."
    end

    if move.castle == "king" then
        new_board[move.from_r][6] = new_board[move.from_r][8]
        new_board[move.from_r][8] = "."
    elseif move.castle == "queen" then
        new_board[move.from_r][4] = new_board[move.from_r][1]
        new_board[move.from_r][1] = "."
    end

    if piece == "P" and move.to_r == 1 then
        local promo = move.promotion or CHESS_PROMOTION_PIECE or "q"
        piece = promo:upper()
    end
    if piece == "p" and move.to_r == 8 then
        local promo = move.promotion or "q"
        piece = promo:lower()
    end
    new_board[move.to_r][move.to_c] = piece
    return new_board
end

local function chess_generate_legal_moves(board, turn)
    local legal = {}
    for r = 1, 8 do
        for c = 1, 8 do
            if chess_owner(board[r][c]) == turn then
                for _, move in ipairs(chess_pseudo_moves_for_piece(board, turn, r, c)) do
                    local next_board = chess_apply_move_clone(board, move)
                    if not chess_is_in_check(next_board, turn) then
                        move.board = next_board
                        legal[#legal + 1] = move
                    end
                end
            end
        end
    end
    return legal
end

local function chess_destination_set(board, turn, r, c)
    local result = {}
    for _, move in ipairs(chess_generate_legal_moves(board, turn)) do
        if move.from_r == r and move.from_c == c then
            result[move.to_r .. ":" .. move.to_c] = true
        end
    end
    return result
end

local function chess_find_move(board, turn, r1, c1, r2, c2)
    for _, move in ipairs(chess_generate_legal_moves(board, turn)) do
        if move.from_r == r1 and move.from_c == c1 and move.to_r == r2 and move.to_c == c2 then
            return move
        end
    end
    return nil
end

local function chess_count_pieces(board)
    local white, black = 0, 0
    for r = 1, 8 do
        for c = 1, 8 do
            local o = chess_owner(board[r][c])
            if o == "w" then white = white + 1 end
            if o == "b" then black = black + 1 end
        end
    end
    return white, black
end

-- ===== UI / APP =====

function GameHub:onDispatcherRegisterActions()
    Dispatcher:registerAction("boardgames_open", {
        category = "none",
        event = "BoardGamesFullplayV40FreshBWOpen",
        title = _("Board Games"),
        general = true,
    })
end

function GameHub:open_settings_store()
    if not ok_luasettings or not LuaSettings then
        self.settings = nil
        return
    end
    local ok, store = pcall(function()
        return LuaSettings:open(DataStorage:getSettingsDir() .. "/boardgames.lua")
    end)
    self.settings = ok and store or nil
end

function GameHub:read_setting(key, default)
    if not self.settings then return default end
    local ok, value = pcall(function()
        return self.settings:readSetting(key, default)
    end)
    if ok then return value end
    return default
end

function GameHub:save_setting(key, value)
    if not self.settings then return end
    pcall(function()
        self.settings:saveSetting(key, value)
        self.settings:flush()
    end)
end

function GameHub:load_preferences()
    self.game_kind = self:read_setting("game_kind", CHECKERS)
    if self.game_kind ~= CHESS and self.game_kind ~= CHECKERS and self.game_kind ~= CONNECT4 and self.game_kind ~= TICTACTOE and self.game_kind ~= MINESWEEPER and self.game_kind ~= BATTLESHIP then self.game_kind = CHECKERS end

    self.mode = self:read_setting("mode", HUMAN_VS_BOT)
    if self.mode ~= HUMAN_VS_HUMAN and self.mode ~= HUMAN_VS_BOT then self.mode = HUMAN_VS_BOT end

    self.visual_theme = self:read_setting("visual_theme", "rb")
    if self.visual_theme ~= "wood" then self.visual_theme = "rb" end

    self.difficulty_index = tonumber(self:read_setting("difficulty_index", 2)) or 2
    if self.difficulty_index < 1 or self.difficulty_index > #DIFFICULTIES then self.difficulty_index = 2 end

    self.checkers_draw_index = tonumber(self:read_setting("checkers_draw_index", 3)) or 3
    if self.checkers_draw_index < 1 or self.checkers_draw_index > #CHECKERS_DRAW_LIMITS then self.checkers_draw_index = 3 end

    self.chess_promotion_piece = self:read_setting("chess_promotion_piece", "q")
    if not ({ q = true, r = true, b = true, n = true })[self.chess_promotion_piece] then
        self.chess_promotion_piece = "q"
    end

    self.chess_en_passant_enabled = self:read_setting("chess_en_passant_enabled", true) ~= false
    self.chess_castling_enabled = self:read_setting("chess_castling_enabled", true) ~= false
    self.minesweeper_flag_mode = self:read_setting("minesweeper_flag_mode", false) == true
    self.stats = normalize_stats(self:read_setting("stats", nil))
end

function GameHub:save_preferences()
    self:save_setting("game_kind", self.game_kind)
    self:save_setting("mode", self.mode)
    self:save_setting("visual_theme", self.visual_theme)
    self:save_setting("difficulty_index", self.difficulty_index)
    self:save_setting("checkers_draw_index", self.checkers_draw_index)
    self:save_setting("chess_promotion_piece", self.chess_promotion_piece)
    self:save_setting("chess_en_passant_enabled", self.chess_en_passant_enabled ~= false)
    self:save_setting("chess_castling_enabled", self.chess_castling_enabled ~= false)
    self:save_setting("minesweeper_flag_mode", self.minesweeper_flag_mode == true)
    self:save_setting("stats", self.stats or fresh_stats())
end

function GameHub:init()
    math.randomseed(os.time())
    self.dimensions = Geometry:new{ w = self.full_width, h = self.full_height }
    self.covers_fullscreen = true
    self._is_open = false
    self.visual_theme = "rb"
    self.key_events = {
        Close = { { "Back" }, doc = _("Close game") },
        Menu = { { "Menu" }, doc = _("Close game") },
    }
    self.ges_events = {
        TapCloseCorner = {
            GestureRange:new{
                ges = "tap",
                range = Geometry:new{ x = 0, y = 0, w = 150, h = 110 },
            },
        },
    }
    ensureBoardGameIconsInstalled()
    self:open_settings_store()
    self.game_kind = CHECKERS
    self.mode = HUMAN_VS_BOT
    self.human_side = "w"
    self.bot_side = "b"
    self.difficulty_index = 2
    self.bot_anim_token = 0
    self.checkers_no_progress = 0
    self.checkers_draw_index = 3
    self.undo_stack = {}
    self.draw_offer = nil
    self.new_game_confirm = false
    self.concede_confirm = false
    self.chess_promotion_piece = "q"
    self.chess_en_passant_enabled = true
    self.chess_castling_enabled = true
    self.chess_rule_focus = "ep"
    self.minesweeper_flag_mode = false
    self.minesweeper = fresh_minesweeper_state(MINESWEEPER_MINE_COUNTS[self.difficulty_index] or MINESWEEPER_MINE_COUNTS[2])
    self.battleship = fresh_battleship_state()
    self.stats = fresh_stats()
    self.result_recorded = false
    self:load_preferences()
    CHESS_PROMOTION_PIECE = self.chess_promotion_piece
    CHESS_EN_PASSANT_ENABLED = self.chess_en_passant_enabled
    CHESS_CASTLING_ENABLED = self.chess_castling_enabled
    CHESS_EN_PASSANT = nil
    CHESS_CASTLING_RIGHTS = fresh_chess_castling_rights()
    if self.game_kind == CHESS then
        self.board = fresh_chess_board()
    elseif self.game_kind == CONNECT4 then
        self.board = fresh_connect4_board()
    elseif self.game_kind == TICTACTOE then
        self.board = fresh_tictactoe_board()
    elseif self.game_kind == MINESWEEPER then
        self.board = blank_board()
        self.minesweeper = fresh_minesweeper_state(MINESWEEPER_MINE_COUNTS[self.difficulty_index] or MINESWEEPER_MINE_COUNTS[2])
    elseif self.game_kind == BATTLESHIP then
        self.board = blank_board()
        self.battleship = fresh_battleship_state()
    else
        self.board = fresh_checkers_board()
    end
    self.turn = "w"
    self.selected = nil
    self.forced_from = nil
    self.bot_plan = nil
    self.game_over = false
    self.dialog = nil
    self.message = "Board Games v1.0.0 loaded."
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function GameHub:addToMainMenu(menu_items)
    menu_items.boardgames = {
        text = _("Board Games"),
        sorting_hint = "tools",
        callback = function() self:show_board() end,
        keep_menu_open = false,
    }
end

function GameHub:invalidate_bot_animation()
    self.bot_anim_token = self.bot_anim_token + 1
    self.bot_plan = nil
end

function GameHub:close_dialog()
    self:invalidate_bot_animation()
    if self.settings_dialog then
        UIManager:close(self.settings_dialog)
        self.settings_dialog = nil
    end
    self._is_open = false
    self.selected = nil
    self.forced_from = nil
    self.bot_plan = nil
    self.new_game_confirm = false
    self.concede_confirm = false
    self.draw_offer = nil
    self[1] = nil
    UIManager:close(self, "ui")
    pcall(function() UIManager:setDirty(nil, "full") end)
end

function GameHub:onClose()
    self:close_dialog()
    return true
end

function GameHub:onMenu()
    self:show_settings_popup()
    return true
end

function GameHub:onTapCloseCorner()
    self:close_dialog()
    return true
end

function GameHub:start_new_game(msg)
    self:invalidate_bot_animation()
    self.selected = nil
    self.forced_from = nil
    self.game_over = false
    self.result_recorded = false
    self.checkers_no_progress = 0
    self.undo_stack = {}
    self.draw_offer = nil
    self.new_game_confirm = false
    self.concede_confirm = false
    CHESS_EN_PASSANT = nil
    CHESS_EN_PASSANT_ENABLED = self.chess_en_passant_enabled ~= false
    CHESS_CASTLING_ENABLED = self.chess_castling_enabled ~= false
    CHESS_CASTLING_RIGHTS = fresh_chess_castling_rights()
    CHESS_PROMOTION_PIECE = self.chess_promotion_piece or "q"
    if self.game_kind == CHECKERS then
        self.board = fresh_checkers_board()
        self.turn = "w"
        if self.mode == HUMAN_VS_BOT then
            self.message = msg or "Checkers solo: You are White. Black bot moves after you."
        else
            self.message = msg or "Checkers two-player: White moves first. Captures are optional."
        end
    elseif self.game_kind == CONNECT4 then
        self.board = fresh_connect4_board()
        self.turn = "w"
        if self.mode == HUMAN_VS_BOT then
            self.message = msg or "Connect 4 solo: You are White. Tap a column to drop a piece."
        else
            self.message = msg or "Connect 4 two-player: White moves first. Tap a column."
        end
    elseif self.game_kind == TICTACTOE then
        self.board = fresh_tictactoe_board()
        self.turn = "w"
        if self.mode == HUMAN_VS_BOT then
            self.message = msg or "Tic Tac Toe solo: You are White X. Black O bot moves after you."
        else
            self.message = msg or "Tic Tac Toe two-player: White X moves first."
        end
    elseif self.game_kind == MINESWEEPER then
        self.board = blank_board()
        self.minesweeper = fresh_minesweeper_state(MINESWEEPER_MINE_COUNTS[self.difficulty_index] or MINESWEEPER_MINE_COUNTS[2])
        self.turn = "w"
        self.mode = HUMAN_VS_BOT
        self.message = msg or "Classic Minesweeper: 9x9 board, 10 mines. Reveal safe squares or flag mines."
    elseif self.game_kind == BATTLESHIP then
        self.board = blank_board()
        self.battleship = fresh_battleship_state()
        self.turn = "w"
        self.mode = HUMAN_VS_BOT
        self.message = msg or "Classic Battleship setup: place your Carrier. Use Options to rotate."
    else
        self.board = fresh_chess_board()
        self.turn = "w"
        CHESS_CASTLING_RIGHTS = fresh_chess_castling_rights()
        if self.mode == HUMAN_VS_BOT then
            self.message = msg or "Chess solo: You are White. Black bot moves after you."
        else
            self.message = msg or "Chess two-player: White moves first."
        end
    end
    self:show_board()
end

function GameHub:toggle_game_kind()
    if self.game_kind == CHECKERS then
        self.game_kind = CHESS
        self:save_preferences()
        self:start_new_game(self.mode == HUMAN_VS_BOT and "Switched to chess. Solo bot mode enabled." or "Switched to chess. Two-player mode enabled.")
    elseif self.game_kind == CHESS then
        self.game_kind = CONNECT4
        self:save_preferences()
        self:start_new_game(self.mode == HUMAN_VS_BOT and "Switched to Connect 4. Solo bot mode enabled." or "Switched to Connect 4. Two-player mode enabled.")
    elseif self.game_kind == CONNECT4 then
        self.game_kind = TICTACTOE
        self:save_preferences()
        self:start_new_game(self.mode == HUMAN_VS_BOT and "Switched to Tic Tac Toe. Solo bot mode enabled." or "Switched to Tic Tac Toe. Two-player mode enabled.")
    elseif self.game_kind == TICTACTOE then
        self.game_kind = MINESWEEPER
        self.mode = HUMAN_VS_BOT
        self:save_preferences()
        self:start_new_game("Switched to Minesweeper. Solo puzzle mode enabled.")
    elseif self.game_kind == MINESWEEPER then
        self.game_kind = BATTLESHIP
        self.mode = HUMAN_VS_BOT
        self:save_preferences()
        self:start_new_game("Switched to Battleship. Solo bot mode enabled.")
    else
        self.game_kind = CHECKERS
        self:save_preferences()
        self:start_new_game(self.mode == HUMAN_VS_BOT and "Switched to checkers. Solo bot mode enabled." or "Switched to checkers. Two-player mode enabled.")
    end
end

function GameHub:set_game_kind(kind)
    if self.game_kind == kind then
        self.message = self:game_label() .. " is already selected."
        self:show_board()
        return
    end
    self.game_kind = kind
    if kind == MINESWEEPER or kind == BATTLESHIP then
        self.mode = HUMAN_VS_BOT
    end
    self:save_preferences()
    self:start_new_game("Switched to " .. self:game_label() .. ".")
end

function GameHub:toggle_mode()
    if self.game_kind == MINESWEEPER or self.game_kind == BATTLESHIP then
        self.mode = HUMAN_VS_BOT
        self:save_preferences()
        self:start_new_game(self.game_kind == BATTLESHIP and "Battleship is solo in this version." or "Minesweeper is a solo puzzle.")
        return
    end
    if self.mode == HUMAN_VS_BOT then
        self.mode = HUMAN_VS_HUMAN
        self:save_preferences()
        if self.game_kind == CHECKERS then
            self:start_new_game("Checkers two-player mode enabled.")
        elseif self.game_kind == CONNECT4 then
            self:start_new_game("Connect 4 two-player mode enabled.")
        elseif self.game_kind == TICTACTOE then
            self:start_new_game("Tic Tac Toe two-player mode enabled.")
        else
            self:start_new_game("Chess two-player mode enabled.")
        end
    else
        self.mode = HUMAN_VS_BOT
        self:save_preferences()
        if self.game_kind == CHECKERS then
            self:start_new_game("Checkers solo mode enabled. You are White.")
        elseif self.game_kind == CONNECT4 then
            self:start_new_game("Connect 4 solo mode enabled. You are White.")
        elseif self.game_kind == TICTACTOE then
            self:start_new_game("Tic Tac Toe solo mode enabled. You are White X.")
        else
            self:start_new_game("Chess solo mode enabled. You are White.")
        end
    end
end


function GameHub:cycle_difficulty()
    self.difficulty_index = (self.difficulty_index % #DIFFICULTIES) + 1
    self:save_preferences()
    if self.game_kind == CHECKERS then
        self.message = "Checkers bot difficulty set to " .. DIFFICULTIES[self.difficulty_index] .. "."
    elseif self.game_kind == CONNECT4 then
        self.message = "Connect 4 bot difficulty set to " .. DIFFICULTIES[self.difficulty_index] .. "."
    elseif self.game_kind == TICTACTOE then
        self.message = "Tic Tac Toe bot difficulty set to " .. DIFFICULTIES[self.difficulty_index] .. "."
    elseif self.game_kind == MINESWEEPER then
        self.minesweeper = fresh_minesweeper_state(MINESWEEPER_MINE_COUNTS[self.difficulty_index] or MINESWEEPER_MINE_COUNTS[2])
        self.board = blank_board()
        self.game_over = false
        self.undo_stack = {}
        self.message = "Classic Minesweeper: 9x9 board with 10 mines."
    elseif self.game_kind == BATTLESHIP then
        self.message = "Battleship bot difficulty set to " .. DIFFICULTIES[self.difficulty_index] .. "."
    else
        self.message = "Chess bot difficulty set to " .. DIFFICULTIES[self.difficulty_index] .. "."
    end
    self:show_board()
end


function GameHub:theme_label()
    return self.visual_theme == "wood" and "Wood" or "Red/Black"
end

function GameHub:toggle_visual_theme()
    self.visual_theme = self.visual_theme == "rb" and "wood" or "rb"
    self:save_preferences()
    if self.game_kind == CHESS then
        self.message = "Chess board stays black/white. Checkers theme set to " .. self:theme_label() .. "."
    else
        self.message = "Checkers theme set to " .. self:theme_label() .. "."
    end
    self:show_board()
end

function GameHub:visual_icon_for_square(r, c, hints)
    local piece = self.board[r][c]
    if self.game_kind == CHECKERS then
        if piece == "w" then return "boardgames/w_checker" end
        if piece == "W" then return "boardgames/w_checker_king" end
        if piece == "b" then return "boardgames/b_checker" end
        if piece == "B" then return "boardgames/b_checker_king" end
        return "boardgames/empty"
    end

    if piece ~= "." then
        local owner = chess_owner(piece)
        local prefix = owner == "w" and "w" or "b"
        return "chess/" .. prefix .. piece:upper()
    end
    return "boardgames/empty"
end

function GameHub:square_background_for(r, c, hints)
    local key = r .. ":" .. c
    if self.selected and self.selected[1] == r and self.selected[2] == c then
        return Blitbuffer.COLOR_DARK_GRAY
    end
    if hints and hints[key] then
        return Blitbuffer.COLOR_GRAY
    end
    return playable_square(r, c) and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
end

function GameHub:current_hints()
    if self.selected and not self.bot_plan then
        if self.game_kind == CHECKERS then
            return checkers_destination_set(self.board, self.turn, self.selected[1], self.selected[2], self.forced_from)
        elseif self.game_kind == CHESS then
            return chess_destination_set(self.board, self.turn, self.selected[1], self.selected[2])
        end
    end
    return nil
end


function GameHub:game_label()
    if self.game_kind == CHECKERS then return "Checkers" end
    if self.game_kind == CONNECT4 then return "Connect 4" end
    if self.game_kind == TICTACTOE then return "Tic Tac Toe" end
    if self.game_kind == MINESWEEPER then return "Minesweeper" end
    if self.game_kind == BATTLESHIP then return "Battleship" end
    return "Chess"
end

function GameHub:record_current_result()
    if not self.game_over or self.result_recorded then return end
    self.stats = normalize_stats(self.stats)
    local row = self.stats[self.game_kind]
    if not row then return end

    local lower = (self.message or ""):lower()
    row.played = (row.played or 0) + 1

    local won = false
    local lost = false
    if lower:match("draw") or lower:match("stalemate") then
        row.draws = (row.draws or 0) + 1
    elseif lower:match("you win") or lower:match("white wins") or lower:match("enemy fleet") or lower:match("cleared") then
        row.wins = (row.wins or 0) + 1
        won = true
    elseif lower:match("bot wins") or lower:match("black wins") or lower:match("your fleet") or lower:match("you conceded") or lower:match("boom") then
        row.losses = (row.losses or 0) + 1
        lost = true
    else
        row.draws = (row.draws or 0) + 1
    end
    if won then
        row.streak = (row.streak or 0) + 1
        if row.streak > (row.best_streak or 0) then row.best_streak = row.streak end
    elseif lost then
        row.streak = 0
    end

    self.result_recorded = true
    self:save_setting("stats", self.stats)
end

function GameHub:clear_stats_for_kind(kind)
    self.stats = normalize_stats(self.stats)
    self.stats[kind] = { played = 0, wins = 0, losses = 0, draws = 0, streak = 0, best_streak = 0 }
    self:save_setting("stats", self.stats)
    self.message = self:label_for_kind(kind) .. " records cleared."
    self:show_board()
end

function GameHub:clear_stats()
    self.stats = fresh_stats()
    self:save_setting("stats", self.stats)
    self.message = "Records cleared."
    self:show_board()
end

function GameHub:short_status()
    local game_text = self:game_label()
    local mode_text = (self.game_kind == MINESWEEPER or self.game_kind == BATTLESHIP) and "Solo" or (self.mode == HUMAN_VS_BOT and "Solo" or "2P")
    local turn_text
    if self.game_over then
        turn_text = "GAME OVER"
    elseif self.game_kind == MINESWEEPER then
        turn_text = self.minesweeper_flag_mode and "Flag" or "Reveal"
    elseif self.game_kind == BATTLESHIP then
        turn_text = self.battleship and self.battleship.view == "fleet" and "Your Fleet" or "Enemy Waters"
    elseif self.bot_plan then
        turn_text = "Bot is thinking"
    elseif self.message and self.message:match("^Bot moved") then
        turn_text = "Your turn"
    else
        turn_text = side_label(self.turn)
    end
    return game_text .. "  " .. mode_text .. "  " .. turn_text
end

function GameHub:status_title()
    local game_text = self:game_label()
    local mode_text = (self.game_kind == MINESWEEPER or self.game_kind == BATTLESHIP) and "Solo" or (self.mode == HUMAN_VS_BOT and "Solo" or "2P")

    if self.bot_plan then
        return game_text .. " | " .. mode_text .. "\nBot is thinking..."
    end

    local detail = self.message or "Tap a piece."

    if self.game_over then
        local clean = detail
        clean = clean:gsub("^Game over:%s*", "")
        clean = clean:gsub("^GAME OVER:%s*", "")
        clean = clean:gsub("^Game over%.%s*", "")
        if clean == "" then clean = "Game over." end
        return game_text .. " | " .. mode_text .. "\nGAME OVER: " .. clean
    end

    if self.game_kind == MINESWEEPER then
        local state = self.minesweeper or fresh_minesweeper_state(MINESWEEPER_MINE_COUNTS[self.difficulty_index] or MINESWEEPER_MINE_COUNTS[2])
        local mode = self.minesweeper_flag_mode and "Flag" or "Reveal"
        local flags_left = (state.mines or 0) - (state.flags or 0)
        local safe_total = ((state.rows or MINESWEEPER_ROWS) * (state.cols or MINESWEEPER_COLS)) - (state.mines or 0)
        local preset = "Classic 9x9"
        return game_text .. " | " .. mode_text .. " | " .. mode .. " | " .. preset .. "\n" .. detail .. "  Flags Left: " .. tostring(flags_left) .. "  Clear: " .. tostring(state.revealed_count or 0) .. "/" .. tostring(safe_total)
    end

    if self.game_kind == BATTLESHIP then
        local state = self.battleship or fresh_battleship_state()
        if state.phase == "setup" then
            local id = state.placing_ship or 1
            local dir = state.place_horizontal ~= false and "H" or "V"
            return game_text .. " | Setup | " .. dir .. "\nPlace " .. battleship_ship_name(id) .. " size " .. tostring(BATTLESHIP_SHIPS[id] or 0) .. ". " .. detail
        end
        local view = state.view == "fleet" and "Your Fleet" or "Enemy Waters"
        local sunk = "Enemy Sunk: " .. tostring(battleship_sunk_count(state.bot_sunk)) .. "/" .. tostring(#BATTLESHIP_SHIPS) ..
            "  Yours Sunk: " .. tostring(battleship_sunk_count(state.player_sunk)) .. "/" .. tostring(#BATTLESHIP_SHIPS)
        return game_text .. " | " .. mode_text .. " | " .. view .. "\n" .. detail .. "  Hits: " .. tostring(state.player_hits or 0) .. "/" .. tostring(state.total_ship_cells or battleship_ship_cell_count()) .. "  " .. sunk
    end

    local turn_text
    if self.message and self.message:match("^Bot moved") then
        turn_text = "Your turn"
    else
        turn_text = side_label(self.turn)
    end

    if self.selected then
        detail = detail .. "  " .. square_name(self.selected[1], self.selected[2])
    end
    return game_text .. " | " .. mode_text .. " | " .. turn_text .. "\n" .. detail
end

-- ===== FULLSCREEN GAMEPLAY HELPERS RESTORED =====

function GameHub:copy_chess_en_passant()
    if not CHESS_EN_PASSANT then return nil end
    return {
        turn = CHESS_EN_PASSANT.turn,
        target_r = CHESS_EN_PASSANT.target_r,
        target_c = CHESS_EN_PASSANT.target_c,
        capture_r = CHESS_EN_PASSANT.capture_r,
        capture_c = CHESS_EN_PASSANT.capture_c,
    }
end

function GameHub:update_chess_castling_rights(move, moving_piece, captured_piece)
    CHESS_CASTLING_RIGHTS = copy_chess_castling_rights(CHESS_CASTLING_RIGHTS)
    local owner = chess_owner(moving_piece)
    if owner then
        local rights = CHESS_CASTLING_RIGHTS[owner]
        if moving_piece == "K" or moving_piece == "k" then
            rights.king = false
            rights.queen = false
        elseif moving_piece == "R" or moving_piece == "r" then
            local home = owner == "w" and 8 or 1
            if move.from_r == home and move.from_c == 1 then
                rights.queen = false
            elseif move.from_r == home and move.from_c == 8 then
                rights.king = false
            end
        end
    end

    local captured_owner = chess_owner(captured_piece)
    if captured_owner and (captured_piece == "R" or captured_piece == "r") then
        local home = captured_owner == "w" and 8 or 1
        local rights = CHESS_CASTLING_RIGHTS[captured_owner]
        if move.to_r == home and move.to_c == 1 then
            rights.queen = false
        elseif move.to_r == home and move.to_c == 8 then
            rights.king = false
        end
    end
end

function GameHub:push_undo_state()
    self.undo_stack = self.undo_stack or {}
    self.undo_stack[#self.undo_stack + 1] = {
        game_kind = self.game_kind,
        mode = self.mode,
        board = clone_board(self.board),
        turn = self.turn,
        selected = self.selected and { self.selected[1], self.selected[2] } or nil,
        forced_from = self.forced_from and { self.forced_from[1], self.forced_from[2] } or nil,
        game_over = self.game_over,
        message = self.message,
        checkers_no_progress = self.checkers_no_progress or 0,
        checkers_draw_index = self.checkers_draw_index or 3,
        chess_promotion_piece = self.chess_promotion_piece or "q",
        chess_en_passant_enabled = self.chess_en_passant_enabled ~= false,
        chess_castling_enabled = self.chess_castling_enabled ~= false,
        chess_rule_focus = self.chess_rule_focus or "ep",
        chess_en_passant = self:copy_chess_en_passant(),
        chess_castling_rights = copy_chess_castling_rights(CHESS_CASTLING_RIGHTS),
        minesweeper = copy_minesweeper_state(self.minesweeper),
        minesweeper_flag_mode = self.minesweeper_flag_mode == true,
        battleship = copy_battleship_state(self.battleship),
    }
    if #self.undo_stack > 30 then
        table.remove(self.undo_stack, 1)
    end
end

function GameHub:undo_move()
    self:invalidate_bot_animation()
    local stack = self.undo_stack or {}
    local state = table.remove(stack)
    if not state then
        self.message = "Nothing to undo."
        self:show_board()
        return
    end
    self.game_kind = state.game_kind
    self.mode = state.mode
    self.board = clone_board(state.board)
    self.turn = state.turn
    self.selected = state.selected
    self.forced_from = state.forced_from
    self.game_over = state.game_over
    self.checkers_no_progress = state.checkers_no_progress or 0
    self.checkers_draw_index = state.checkers_draw_index or 3
    self.chess_promotion_piece = state.chess_promotion_piece or "q"
    self.chess_en_passant_enabled = state.chess_en_passant_enabled ~= false
    self.chess_castling_enabled = state.chess_castling_enabled ~= false
    self.chess_rule_focus = state.chess_rule_focus or "ep"
    self.minesweeper = copy_minesweeper_state(state.minesweeper)
    self.minesweeper_flag_mode = state.minesweeper_flag_mode == true
    self.battleship = copy_battleship_state(state.battleship)
    CHESS_PROMOTION_PIECE = self.chess_promotion_piece
    CHESS_EN_PASSANT_ENABLED = self.chess_en_passant_enabled
    CHESS_CASTLING_ENABLED = self.chess_castling_enabled
    CHESS_EN_PASSANT = state.chess_en_passant
    CHESS_CASTLING_RIGHTS = copy_chess_castling_rights(state.chess_castling_rights)
    self.draw_offer = nil
    self.new_game_confirm = false
    if self.game_kind == MINESWEEPER or self.game_kind == BATTLESHIP then
        self.message = "Move undone."
    else
        self.message = "Move undone. " .. side_label(self.turn) .. " to move."
    end
    self:show_board()
end

function GameHub:declare_draw(msg)
    self:invalidate_bot_animation()
    self.game_over = true
    self.selected = nil
    self.forced_from = nil
    self.bot_plan = nil
    self.draw_offer = nil
    self.message = msg or "Draw."
    self:show_board()
end

function GameHub:request_draw()
    if self.game_over then
        self.message = "Game is already over."
        self:show_board()
        return
    end
    if self.game_kind == MINESWEEPER then
        self.message = "Minesweeper does not use draws. Clear every safe square to win."
        self:show_board()
        return
    elseif self.game_kind == BATTLESHIP then
        self.message = "Battleship does not use draws. Sink every enemy ship to win."
        self:show_board()
        return
    end
    if self.mode == HUMAN_VS_BOT then
        self:declare_draw("Draw agreed.")
        return
    end
    if self.draw_offer and self.draw_offer ~= self.turn then
        self:declare_draw("Draw agreed by both players.")
        return
    end
    self.draw_offer = self.turn
    self.message = (self.turn == "w" and "White" or "Black") .. " offered a draw. Other player can tap Draw to accept."
    self:show_board()
end

function GameHub:request_new_game()
    if self.new_game_confirm then
        self.new_game_confirm = false
        self:start_new_game("New game started.")
        return
    end
    self.new_game_confirm = true
    self.message = "Tap New again to confirm."
    self:show_board()
end


function GameHub:request_concede()
    if self.game_over then
        self.concede_confirm = false
        self.message = "Game is already over."
        self:show_board()
        return
    end

    if not self.concede_confirm then
        self.concede_confirm = true
        self.new_game_confirm = false
        self.message = "Tap Confirm Concede to forfeit."
        self:show_board()
        return
    end

    self.concede_confirm = false
    self.new_game_confirm = false
    self.draw_offer = nil
    self.selected = nil
    self.forced_from = nil
    self:invalidate_bot_animation()
    self.game_over = true

    if self.game_kind == MINESWEEPER then
        self.message = "Minesweeper ended."
    elseif self.game_kind == BATTLESHIP then
        self.message = "You conceded. Bot wins."
    elseif self.mode == HUMAN_VS_BOT then
        self.message = "You conceded. Bot wins."
    else
        local loser = self.turn
        local winner = loser == "w" and "Black" or "White"
        self.message = side_label(loser) .. " conceded. " .. winner .. " wins."
    end

    self:show_board()
end


function GameHub:cycle_checkers_draw_limit()
    self.checkers_draw_index = ((self.checkers_draw_index or 3) % #CHECKERS_DRAW_LIMITS) + 1
    self:save_preferences()
    self.message = "Checkers draw limit set to " .. tostring(CHECKERS_DRAW_LIMITS[self.checkers_draw_index]) .. " no-progress turns."
    self:show_board()
end

function GameHub:cycle_promotion_piece()
    local order = { "q", "r", "b", "n" }
    local current = self.chess_promotion_piece or "q"
    local idx = 1
    for i, p in ipairs(order) do
        if p == current then idx = i break end
    end
    idx = (idx % #order) + 1
    self.chess_promotion_piece = order[idx]
    CHESS_PROMOTION_PIECE = self.chess_promotion_piece
    self:save_preferences()
    local names = { q = "Queen", r = "Rook", b = "Bishop", n = "Knight" }
    self.message = "Pawn promotion set to " .. names[self.chess_promotion_piece] .. "."
    self:show_board()
end

function GameHub:promotion_label()
    local labels = { q = "Q", r = "R", b = "B", n = "N" }
    return labels[self.chess_promotion_piece or "q"] or "Q"
end

function GameHub:toggle_chess_en_passant()
    self.chess_en_passant_enabled = not (self.chess_en_passant_enabled ~= false)
    CHESS_EN_PASSANT_ENABLED = self.chess_en_passant_enabled
    CHESS_EN_PASSANT = nil
    self.selected = nil
    self.chess_rule_focus = "castle"
    self:save_preferences()
    self.message = self.chess_en_passant_enabled and "En passant enabled." or "En passant disabled."
    self:show_board()
end

function GameHub:toggle_chess_castling()
    self.chess_castling_enabled = not (self.chess_castling_enabled ~= false)
    CHESS_CASTLING_ENABLED = self.chess_castling_enabled
    self.selected = nil
    self.chess_rule_focus = "ep"
    self:save_preferences()
    self.message = self.chess_castling_enabled and "Castling enabled." or "Castling disabled."
    self:show_board()
end

function GameHub:toggle_minesweeper_mode()
    self.minesweeper_flag_mode = not self.minesweeper_flag_mode
    self:save_preferences()
    self.message = self.minesweeper_flag_mode and "Minesweeper flag mode. Tap hidden squares to mark mines." or "Minesweeper reveal mode. Tap hidden squares to uncover them."
    self:show_board()
end

function GameHub:toggle_battleship_view()
    if not self.battleship then
        self.battleship = fresh_battleship_state()
    end
    self.battleship.view = self.battleship.view == "fleet" and "enemy" or "fleet"
    self.message = self.battleship.view == "fleet" and "Showing your fleet. Enemy hits are marked X." or "Showing enemy waters. Tap a square to fire."
    self:show_board()
end

function GameHub:randomize_battleship_fleet()
    if not self.battleship then
        self.battleship = fresh_battleship_state()
    end
    local ships, ids, lengths = battleship_random_fleet()
    self.battleship.player_ships = ships
    self.battleship.player_ship_ids = ids
    self.battleship.player_ship_lengths = lengths
    self.battleship.player_sunk = {}
    self.battleship.bot_shots = fresh_battleship_shot_grid()
    self.battleship.bot_hits = 0
    self.battleship.phase = "battle"
    self.battleship.placing_ship = #BATTLESHIP_SHIPS + 1
    self.battleship.view = "enemy"
    self.undo_stack = {}
    self.message = "Your fleet was randomized and ready. Fire at enemy waters."
    self:show_board()
end

function GameHub:toggle_battleship_orientation()
    if not self.battleship then
        self.battleship = fresh_battleship_state()
    end
    self.battleship.place_horizontal = not (self.battleship.place_horizontal ~= false)
    self.message = self.battleship.place_horizontal and "Ship placement set to horizontal." or "Ship placement set to vertical."
    self:show_board()
end

function GameHub:rule_button_label()
    if self.game_kind == CHESS then
        if (self.chess_rule_focus or "ep") == "castle" then
            return self.chess_castling_enabled ~= false and _("Castle: On") or _("Castle: Off")
        end
        return self.chess_en_passant_enabled ~= false and _("EP: On") or _("EP: Off")
    end
    if self.game_kind == MINESWEEPER then
        return self.minesweeper_flag_mode and _("Mode: Flag") or _("Mode: Reveal")
    end
    if self.game_kind == BATTLESHIP then
        if self.battleship and self.battleship.phase == "setup" then
            return self.battleship.place_horizontal == false and _("Place: V") or _("Place: H")
        end
        return self.battleship and self.battleship.view == "fleet" and _("Enemy") or _("Fleet")
    end
    return _("Draw: ") .. tostring(CHECKERS_DRAW_LIMITS[self.checkers_draw_index or 3] or 80)
end

function GameHub:run_rule_button()
    if self.game_kind == CHESS then
        if (self.chess_rule_focus or "ep") == "castle" then
            self:toggle_chess_castling()
        else
            self:toggle_chess_en_passant()
        end
    elseif self.game_kind == MINESWEEPER then
        self:toggle_minesweeper_mode()
    elseif self.game_kind == BATTLESHIP then
        if self.battleship and self.battleship.phase == "setup" then
            self:toggle_battleship_orientation()
        else
            self:toggle_battleship_view()
        end
    else
        self:cycle_checkers_draw_limit()
    end
end

function GameHub:close_settings_popup()
    if self.settings_dialog then
        UIManager:close(self.settings_dialog, "ui")
        self.settings_dialog = nil
    end
end

function GameHub:settings_mode_text()
    if self.game_kind == MINESWEEPER or self.game_kind == BATTLESHIP then
        return _("Mode: Solo")
    end
    return self.mode == HUMAN_VS_BOT and _("Mode: Solo") or _("Mode: 2 Player")
end

function GameHub:settings_level_text()
    if self.game_kind == MINESWEEPER then
        return _("Classic: 9x9 / 10")
    end
    return _("Bot Level: ") .. _(DIFFICULTIES[self.difficulty_index])
end

function GameHub:show_game_select_popup()
    self:close_settings_popup()

    local popup
    local function close_popup()
        if popup then
            UIManager:close(popup, "ui")
            popup = nil
            self.settings_dialog = nil
        end
    end

    local function choose(kind)
        close_popup()
        self:set_game_kind(kind)
        if self._is_open then self:show_settings_popup() end
    end
    local function game_choice(kind, label)
        return (self.game_kind == kind and "[x] " or "[ ] ") .. label
    end

    popup = ButtonDialog:new{
        title = _("        Choose Game        "),
        title_align = "center",
        buttons = {
            {
                { text = _(game_choice(CHECKERS, "Checkers")), callback = function() choose(CHECKERS) end },
                { text = _(game_choice(CHESS, "Chess")), callback = function() choose(CHESS) end },
            },
            {
                { text = _(game_choice(CONNECT4, "Connect 4")), callback = function() choose(CONNECT4) end },
                { text = _(game_choice(TICTACTOE, "Tic Tac Toe")), callback = function() choose(TICTACTOE) end },
            },
            {
                { text = _(game_choice(MINESWEEPER, "Minesweeper")), callback = function() choose(MINESWEEPER) end },
                { text = _(game_choice(BATTLESHIP, "Battleship")), callback = function() choose(BATTLESHIP) end },
            },
            {
                { text = _("Back"), callback = function()
                    close_popup()
                    if self._is_open then self:show_settings_popup() end
                end },
                { text = _("Close"), callback = close_popup },
            },
        },
    }
    self.settings_dialog = popup
    UIManager:show(popup, "ui")
end

function GameHub:show_game_options_popup()
    self:close_settings_popup()

    local promotion_names = { q = "Queen", r = "Rook", b = "Bishop", n = "Knight" }
    local concede_text = self.concede_confirm and _("Confirm Concede") or _("Concede")
    local popup
    local function close_popup()
        if popup then
            UIManager:close(popup, "ui")
            popup = nil
            self.settings_dialog = nil
        end
    end

    local function refresh_here(callback)
        close_popup()
        callback()
        if self._is_open then self:show_game_options_popup() end
    end

    local rows = {}
    if self.game_kind == CHESS then
        rows[#rows + 1] = {
            { text = checked_label(self.chess_castling_enabled ~= false, _("Castling")), callback = function() refresh_here(function() self:toggle_chess_castling() end) end },
            { text = checked_label(self.chess_en_passant_enabled ~= false, _("En Passant")), callback = function() refresh_here(function() self:toggle_chess_en_passant() end) end },
        }
        rows[#rows + 1] = {
            { text = _("Promote: ") .. _(promotion_names[self.chess_promotion_piece or "q"] or "Queen"), callback = function() refresh_here(function() self:cycle_promotion_piece() end) end },
            { text = concede_text, callback = function() refresh_here(function() self:request_concede() end) end },
        }
    elseif self.game_kind == CHECKERS then
        rows[#rows + 1] = {
            { text = _("Draw Limit: ") .. tostring(CHECKERS_DRAW_LIMITS[self.checkers_draw_index or 3] or 80), callback = function() refresh_here(function() self:cycle_checkers_draw_limit() end) end },
            { text = concede_text, callback = function() refresh_here(function() self:request_concede() end) end },
        }
    elseif self.game_kind == CONNECT4 then
        rows[#rows + 1] = {
            { text = _("Rule: Tap a Column"), callback = function()
                refresh_here(function()
                    self.message = "Connect 4: tap any square in a column to drop your piece."
                    self:show_board()
                end)
            end },
            { text = concede_text, callback = function() refresh_here(function() self:request_concede() end) end },
        }
    elseif self.game_kind == TICTACTOE then
        rows[#rows + 1] = {
            { text = _("Rule: Three in a Row"), callback = function()
                refresh_here(function()
                    self.message = "Tic Tac Toe: tap an empty square. First to three in a row wins."
                    self:show_board()
                end)
            end },
            { text = concede_text, callback = function() refresh_here(function() self:request_concede() end) end },
        }
    elseif self.game_kind == MINESWEEPER then
        rows[#rows + 1] = {
            { text = self.minesweeper_flag_mode and _("Tap Mode: Flag") or _("Tap Mode: Reveal"), callback = function() refresh_here(function() self:toggle_minesweeper_mode() end) end },
            { text = _("Rule: Avoid Mines"), callback = function()
                refresh_here(function()
                    self.message = "Classic Minesweeper: 9x9 board, 10 mines. Reveal every safe square."
                    self:show_board()
                end)
            end },
        }
        rows[#rows + 1] = {
            { text = _("Safe Opening"), callback = function()
                refresh_here(function()
                    self.message = "The first reveal protects that square and its neighbors, then numbers guide the flags."
                    self:show_board()
                end)
            end },
            { text = concede_text, callback = function() refresh_here(function() self:request_concede() end) end },
        }
    elseif self.game_kind == BATTLESHIP then
        rows[#rows + 1] = {
            { text = self.battleship and self.battleship.view == "fleet" and _("View: Your Fleet") or _("View: Enemy Waters"), callback = function() refresh_here(function() self:toggle_battleship_view() end) end },
            { text = _("Randomize Fleet"), callback = function() refresh_here(function() self:randomize_battleship_fleet() end) end },
        }
        rows[#rows + 1] = {
            { text = self.battleship and self.battleship.place_horizontal == false and _("Place: Vertical") or _("Place: Horizontal"), callback = function() refresh_here(function() self:toggle_battleship_orientation() end) end },
            { text = concede_text, callback = function() refresh_here(function() self:request_concede() end) end },
        }
        rows[#rows + 1] = {
            { text = _("Rule: Sink Ships"), callback = function()
                refresh_here(function()
                    self.message = "Classic Battleship: 10x10 grid, five ships, call shots until one fleet sinks."
                    self:show_board()
                end)
            end },
            { text = _("Setup Help"), callback = function()
                refresh_here(function()
                    self.message = "Setup: choose horizontal or vertical, then tap the bow/start square for each ship."
                    self:show_board()
                end)
            end },
        }
    end

    rows[#rows + 1] = {
        { text = _("Back"), callback = function()
            close_popup()
            if self._is_open then self:show_settings_popup() end
        end },
        { text = _("Close"), callback = close_popup },
    }

    popup = ButtonDialog:new{
        title = _("        ") .. _(self:game_label()) .. _(" Options        "),
        title_align = "center",
        buttons = rows,
    }
    self.settings_dialog = popup
    UIManager:show(popup, "ui")
end

function GameHub:show_about_popup()
    self:close_settings_popup()

    local popup
    local function close_popup()
        if popup then
            UIManager:close(popup, "ui")
            popup = nil
            self.settings_dialog = nil
        end
    end

    popup = ButtonDialog:new{
        title = _("        About Board Games        "),
        title_align = "center",
        buttons = {
            {
                { text = _("Version 1.0.0"), callback = function() end },
            },
            {
                { text = _("Made By KitanaCode"), callback = function() end },
            },
            {
                { text = _("Back"), callback = function()
                    close_popup()
                    if self._is_open then self:show_settings_popup() end
                end },
                { text = _("Close"), callback = close_popup },
            },
        },
    }
    self.settings_dialog = popup
    UIManager:show(popup, "ui")
end

function GameHub:show_rules_popup(kind)
    self:close_settings_popup()

    local titles = {
        [CHECKERS] = "Checkers Rules",
        [CHESS] = "Chess Rules",
        [CONNECT4] = "Connect 4 Rules",
        [TICTACTOE] = "Tic Tac Toe Rules",
        [MINESWEEPER] = "Minesweeper Rules",
        [BATTLESHIP] = "Battleship Rules",
    }
    local rules = {
        [CHECKERS] = {
            "Move diagonally on dark squares.",
            "Jump enemy pieces to capture. Follow-up jumps continue with the same piece.",
            "Reach the far row to become a king.",
            "Kings move and jump diagonally both ways.",
        },
        [CHESS] = {
            "Protect your king and attack the enemy king.",
            "Checkmate wins. Stalemate draws.",
            "Castling, en passant, and promotion are in Options.",
            "Tap a piece, then tap a highlighted destination.",
        },
        [CONNECT4] = {
            "Tap a column to drop your piece.",
            "First to connect four in a row wins.",
            "Rows can be horizontal, vertical, or diagonal.",
        },
        [TICTACTOE] = {
            "Tap an empty square to place your mark.",
            "First to three in a row wins.",
            "If the board fills with no winner, it is a draw.",
        },
        [MINESWEEPER] = {
            "Classic beginner board: 9x9 with 10 mines.",
            "Reveal safe squares and avoid mines.",
            "Numbers show nearby mines.",
            "Use Flag mode to mark mines. The flag counter shows flags left.",
            "First reveal protects that square and its neighbors.",
            "Tap a revealed number to clear matching flagged neighbors.",
        },
        [BATTLESHIP] = {
            "Classic board: 10x10 with five ships.",
            "Fleet: Carrier 5, Battleship 4, Cruiser 3, Submarine 3, Destroyer 2.",
            "Setup bar: Rotate H/V, Random Fleet, Undo, Settings.",
            "Rotate chooses ship direction. Tap the starting square to place it.",
            "Battle bar: Enemy Waters, Your Fleet, Undo, Settings.",
            "X means hit. o means miss.",
            "Your Fleet shows your ships and incoming shots.",
            "Enemy Waters is where you fire.",
            "Sink every enemy ship before the bot sinks yours.",
        },
    }

    local popup
    local function close_popup()
        if popup then
            UIManager:close(popup, "ui")
            popup = nil
            self.settings_dialog = nil
        end
    end

    local rows = {}
    for _, line in ipairs(rules[kind] or {}) do
        rows[#rows + 1] = {
            { text = line, callback = function() end },
        }
    end
    rows[#rows + 1] = {
        { text = _("Back"), callback = function()
            close_popup()
            if self._is_open then self:show_help_popup() end
        end },
        { text = _("Close"), callback = close_popup },
    }

    popup = ButtonDialog:new{
        title = _("        ") .. _(titles[kind] or "Rules") .. _("        "),
        title_align = "center",
        buttons = rows,
    }
    self.settings_dialog = popup
    UIManager:show(popup, "ui")
end

function GameHub:show_help_popup()
    self:close_settings_popup()

    local popup
    local function close_popup()
        if popup then
            UIManager:close(popup, "ui")
            popup = nil
            self.settings_dialog = nil
        end
    end

    local function show_rules(kind)
        close_popup()
        self:show_rules_popup(kind)
    end

    popup = ButtonDialog:new{
        title = _("        Help / Rules        "),
        title_align = "center",
        buttons = {
            {
                { text = _("Checkers"), callback = function() show_rules(CHECKERS) end },
                { text = _("Chess"), callback = function() show_rules(CHESS) end },
            },
            {
                { text = _("Connect 4"), callback = function() show_rules(CONNECT4) end },
                { text = _("Tic Tac Toe"), callback = function() show_rules(TICTACTOE) end },
            },
            {
                { text = _("Minesweeper"), callback = function() show_rules(MINESWEEPER) end },
                { text = _("Battleship"), callback = function() show_rules(BATTLESHIP) end },
            },
            {
                { text = _("Back"), callback = function()
                    close_popup()
                    if self._is_open then self:show_settings_popup() end
                end },
                { text = _("Close"), callback = close_popup },
            },
        },
    }
    self.settings_dialog = popup
    UIManager:show(popup, "ui")
end

function GameHub:stats_line(kind)
    self.stats = normalize_stats(self.stats)
    local row = self.stats[kind] or {}
    local played = row.played or 0
    local rate = played > 0 and math.floor(((row.wins or 0) * 100 / played) + 0.5) or 0
    return self:label_for_kind(kind) .. ": " ..
        tostring(row.wins or 0) .. "W " ..
        tostring(row.losses or 0) .. "L " ..
        tostring(row.draws or 0) .. "D  " ..
        tostring(played) .. "P  " .. tostring(rate) .. "%"
end

function GameHub:label_for_kind(kind)
    if kind == CHECKERS then return "Checkers" end
    if kind == CHESS then return "Chess" end
    if kind == CONNECT4 then return "Connect 4" end
    if kind == TICTACTOE then return "Tic Tac Toe" end
    if kind == MINESWEEPER then return "Minesweeper" end
    if kind == BATTLESHIP then return "Battleship" end
    return "Game"
end

function GameHub:show_record_detail_popup(kind)
    self:close_settings_popup()
    self.stats = normalize_stats(self.stats)
    local row = self.stats[kind] or {}
    local played = row.played or 0
    local rate = played > 0 and math.floor(((row.wins or 0) * 100 / played) + 0.5) or 0

    local popup
    local function close_popup()
        if popup then
            UIManager:close(popup, "ui")
            popup = nil
            self.settings_dialog = nil
        end
    end

    popup = ButtonDialog:new{
        title = _("        ") .. _(self:label_for_kind(kind)) .. _(" Records        "),
        title_align = "center",
        buttons = {
            { { text = _("Played: ") .. tostring(played), callback = function() end } },
            { { text = _("Wins: ") .. tostring(row.wins or 0) .. _("   Losses: ") .. tostring(row.losses or 0), callback = function() end } },
            { { text = _("Draws: ") .. tostring(row.draws or 0) .. _("   Win Rate: ") .. tostring(rate) .. "%", callback = function() end } },
            { { text = _("Streak: ") .. tostring(row.streak or 0) .. _("   Best: ") .. tostring(row.best_streak or 0), callback = function() end } },
            { { text = _("Reset This Game"), callback = function()
                close_popup()
                self:clear_stats_for_kind(kind)
                if self._is_open then self:show_records_popup() end
            end } },
            {
                { text = _("Back"), callback = function()
                    close_popup()
                    if self._is_open then self:show_records_popup() end
                end },
                { text = _("Close"), callback = close_popup },
            },
        },
    }
    self.settings_dialog = popup
    UIManager:show(popup, "ui")
end

function GameHub:show_records_popup()
    self:close_settings_popup()
    self.stats = normalize_stats(self.stats)

    local popup
    local function close_popup()
        if popup then
            UIManager:close(popup, "ui")
            popup = nil
            self.settings_dialog = nil
        end
    end

    local function show_detail(kind)
        close_popup()
        self:show_record_detail_popup(kind)
    end

    popup = ButtonDialog:new{
        title = _("        Records        "),
        title_align = "center",
        buttons = {
            {
                { text = self:stats_line(CHECKERS), callback = function() show_detail(CHECKERS) end },
            },
            {
                { text = self:stats_line(CHESS), callback = function() show_detail(CHESS) end },
            },
            {
                { text = self:stats_line(CONNECT4), callback = function() show_detail(CONNECT4) end },
            },
            {
                { text = self:stats_line(TICTACTOE), callback = function() show_detail(TICTACTOE) end },
            },
            {
                { text = self:stats_line(MINESWEEPER), callback = function() show_detail(MINESWEEPER) end },
            },
            {
                { text = self:stats_line(BATTLESHIP), callback = function() show_detail(BATTLESHIP) end },
            },
            {
                { text = _("Clear Records"), callback = function()
                    close_popup()
                    self:clear_stats()
                    if self._is_open then self:show_settings_popup() end
                end },
            },
            {
                { text = _("Back"), callback = function()
                    close_popup()
                    if self._is_open then self:show_settings_popup() end
                end },
                { text = _("Close"), callback = close_popup },
            },
        },
    }
    self.settings_dialog = popup
    UIManager:show(popup, "ui")
end

function GameHub:show_settings_popup()
    self:close_settings_popup()

    local game_text = _("Game: ") .. _(self:game_label())
    local mode_text = self:settings_mode_text()
    local level_text = self:settings_level_text()
    local new_text = self.new_game_confirm and _("Confirm New Game") or _("New Game")

    local popup
    local function close_popup()
        if popup then
            UIManager:close(popup, "ui")
            popup = nil
            self.settings_dialog = nil
        end
    end

    local function refresh(callback)
        close_popup()
        callback()
        if self._is_open then self:show_settings_popup() end
    end

    local rows = {
        {
            { text = game_text, callback = function()
                self.message = "Current game: " .. self:game_label() .. "."
                self:show_board()
            end },
        },
        {
            { text = _("Choose Game"), callback = function()
                close_popup()
                self:show_game_select_popup()
            end },
            { text = _("Game Options"), callback = function()
                close_popup()
                self:show_game_options_popup()
            end },
        },
        {
            { text = new_text, callback = function() refresh(function() self:request_new_game() end) end },
        },
        {
            { text = mode_text, callback = function() refresh(function() self:toggle_mode() end) end },
            { text = level_text, callback = function() refresh(function() self:cycle_difficulty() end) end },
        },
        {
            { text = _("Help / Rules"), callback = function()
                close_popup()
                self:show_help_popup()
            end },
            { text = _("Records"), callback = function()
                close_popup()
                self:show_records_popup()
            end },
        },
        {
            { text = _("About"), callback = function()
                close_popup()
                self:show_about_popup()
            end },
        },
        {
            { text = _("Close Settings"), callback = close_popup },
            { text = _("Exit Game"), callback = function()
                close_popup()
                self:close_dialog()
            end },
        },
    }

    popup = ButtonDialog:new{
        title = _("        Board Game Settings        "),
        title_align = "center",
        buttons = rows,
    }
    self.settings_dialog = popup
    UIManager:show(popup, "ui")
end

function GameHub:buildControlsWidget(width)
    if self.game_kind == BATTLESHIP then
        local state = self.battleship or fresh_battleship_state()
        local battleship_rows
        if state.phase == "setup" then
            battleship_rows = {
                {
                    { text = state.place_horizontal == false and _("Rotate: V") or _("Rotate: H"), callback = function()
                        self:toggle_battleship_orientation()
                    end },
                    { text = _("Random Fleet"), callback = function()
                        self:randomize_battleship_fleet()
                    end },
                    { text = _("Undo"), callback = function()
                        self:undo_move()
                    end },
                    { text = _("Settings"), callback = function()
                        self:show_settings_popup()
                    end },
                },
            }
        else
            battleship_rows = {
                {
                    { text = _("Enemy Waters"), callback = function()
                        state.view = "enemy"
                        self.message = "Showing enemy waters. Tap a square to fire."
                        self:show_board()
                    end },
                    { text = _("Your Fleet"), callback = function()
                        state.view = "fleet"
                        self.message = "Showing your fleet. Enemy hits are marked X."
                        self:show_board()
                    end },
                    { text = _("Undo"), callback = function()
                        self:undo_move()
                    end },
                    { text = _("Settings"), callback = function()
                        self:show_settings_popup()
                    end },
                },
            }
        end
        return ButtonTable:new{
            buttons = battleship_rows,
            width = width,
            shrink_unneeded_width = false,
            zero_sep = true,
            sep_width = 0,
            addVerticalSpan = function() end,
        }
    end

    local draw_text = self.draw_offer and _("Accept Draw") or _("Draw")
    if self.game_kind == MINESWEEPER then
        draw_text = self.minesweeper_flag_mode and _("Reveal") or _("Flag")
    end

    local rows = {
        {
            { text = _("Settings"), callback = function() self:show_settings_popup() end },
            { text = _("Undo"), callback = function() self:undo_move() end },
            { text = draw_text, callback = function()
                if self.game_kind == MINESWEEPER then
                    self:toggle_minesweeper_mode()
                else
                    self:request_draw()
                end
            end },
            { text = _("Close"), callback = function() self:close_dialog() end },
        },
    }

    return ButtonTable:new{
        buttons = rows,
        width = width,
        shrink_unneeded_width = false,
        zero_sep = true,
        sep_width = 0,
        addVerticalSpan = function() end,
    }
end



function GameHub:tictactoe_icon_for_square(r, c)
    local piece = self.board[r][c]
    if piece == "w" then return "boardgames/ttt_w" end
    if piece == "b" then return "boardgames/ttt_b" end
    return "boardgames/ttt_empty"
end

function GameHub:buildTicTacToeWidget(board_size)
    local square_size = math.floor(board_size / TTT_COLS)
    local actual_size = square_size * TTT_COLS
    local rows = {}
    for r = 1, TTT_ROWS do
        local row = {}
        for c = 1, TTT_COLS do
            local rr, cc = r, c
            row[#row + 1] = {
                text = nil,
                icon = self:tictactoe_icon_for_square(rr, cc),
                alpha = true,
                icon_width = square_size,
                icon_height = square_size,
                width = square_size,
                height = square_size,
                background = Blitbuffer.COLOR_WHITE,
                bordersize = 0,
                margin = 0,
                padding = 0,
                padding_h = 0,
                padding_v = 0,
                callback = function() self:on_square_tap(rr, cc) end,
            }
        end
        rows[#rows + 1] = row
    end
    return ButtonTable:new{
        buttons = rows,
        width = actual_size,
        shrink_unneeded_width = false,
        zero_sep = true,
        sep_width = 0,
        addVerticalSpan = function() end,
    }
end

function GameHub:minesweeper_cell_text(r, c)
    local state = self.minesweeper
    if not state then return "." end
    if self.game_over and state.flagged[r][c] and not state.mined[r][c] then return "!" end
    if self.game_over and state.mined[r][c] then return "*" end
    if state.flagged[r][c] and not state.revealed[r][c] then return "F" end
    if not state.revealed[r][c] then return " " end
    if state.mined[r][c] then return "*" end
    local count = minesweeper_adjacent_count(state, r, c)
    if count == 0 then return " " end
    return tostring(count)
end

function GameHub:minesweeper_cell_background(r, c)
    local state = self.minesweeper
    if not state then return Blitbuffer.COLOR_WHITE end
    if self.game_over and state.flagged[r][c] and not state.mined[r][c] then return Blitbuffer.COLOR_WHITE end
    if self.game_over and state.mined[r][c] then return Blitbuffer.COLOR_GRAY end
    if state.revealed[r][c] then return Blitbuffer.COLOR_WHITE end
    if state.flagged[r][c] then return Blitbuffer.COLOR_GRAY end
    return playable_square(r, c) and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY
end

function GameHub:buildMinesweeperWidget(board_size)
    local state = self.minesweeper or fresh_minesweeper_state(MINESWEEPER_MINE_COUNTS[self.difficulty_index] or MINESWEEPER_MINE_COUNTS[2])
    local rows_count = state.rows or MINESWEEPER_ROWS
    local cols_count = state.cols or MINESWEEPER_COLS
    local square_size = math.floor(board_size / cols_count)
    local actual_size = square_size * cols_count
    local rows = {}
    for r = 1, rows_count do
        local row = {}
        for c = 1, cols_count do
            local rr, cc = r, c
            row[#row + 1] = {
                text = self:minesweeper_cell_text(rr, cc),
                width = square_size,
                height = square_size,
                background = self:minesweeper_cell_background(rr, cc),
                bordersize = 1,
                margin = 0,
                padding = 0,
                padding_h = 0,
                padding_v = 0,
                callback = function() self:on_square_tap(rr, cc) end,
            }
        end
        rows[#rows + 1] = row
    end
    return ButtonTable:new{
        buttons = rows,
        width = actual_size,
        shrink_unneeded_width = false,
        zero_sep = true,
        sep_width = 0,
        addVerticalSpan = function() end,
    }
end

function GameHub:battleship_cell_text(r, c)
    local state = self.battleship
    if not state then return "." end
    if state.phase == "setup" then
        if state.player_ships[r][c] then return battleship_ship_mark(state.player_ship_ids[r][c]) end
        return "."
    end
    if state.view == "fleet" then
        if state.bot_shots[r][c] and state.player_ships[r][c] then return "X" end
        if state.bot_shots[r][c] then return "o" end
        if state.player_ships[r][c] then return battleship_ship_mark(state.player_ship_ids[r][c]) end
        return "."
    end
    if state.player_shots[r][c] and state.bot_ships[r][c] then return "X" end
    if state.player_shots[r][c] then return "o" end
    return "."
end

function GameHub:battleship_cell_background(r, c)
    local state = self.battleship
    if not state then return Blitbuffer.COLOR_WHITE end
    if state.phase == "setup" then
        if state.player_ships[r][c] then return Blitbuffer.COLOR_WHITE end
        return Blitbuffer.COLOR_GRAY
    end
    if state.view == "fleet" then
        if state.bot_shots[r][c] and state.player_ships[r][c] then return Blitbuffer.COLOR_GRAY end
        if state.player_ships[r][c] then return Blitbuffer.COLOR_WHITE end
        return Blitbuffer.COLOR_GRAY
    end
    if state.player_shots[r][c] and state.bot_ships[r][c] then return Blitbuffer.COLOR_GRAY end
    if state.player_shots[r][c] then return Blitbuffer.COLOR_WHITE end
    return Blitbuffer.COLOR_GRAY
end

function GameHub:buildBattleshipWidget(board_size)
    local state = self.battleship or fresh_battleship_state()
    local rows_count = state.rows or BATTLESHIP_ROWS
    local cols_count = state.cols or BATTLESHIP_COLS
    local square_size = math.floor(board_size / cols_count)
    local actual_size = square_size * cols_count
    local rows = {}
    for r = 1, rows_count do
        local row = {}
        for c = 1, cols_count do
            local rr, cc = r, c
            row[#row + 1] = {
                text = self:battleship_cell_text(rr, cc),
                width = square_size,
                height = square_size,
                background = self:battleship_cell_background(rr, cc),
                bordersize = 1,
                margin = 0,
                padding = 0,
                padding_h = 0,
                padding_v = 0,
                callback = function() self:on_square_tap(rr, cc) end,
            }
        end
        rows[#rows + 1] = row
    end
    return ButtonTable:new{
        buttons = rows,
        width = actual_size,
        shrink_unneeded_width = false,
        zero_sep = true,
        sep_width = 0,
        addVerticalSpan = function() end,
    }
end

function GameHub:connect4_icon_for_square(r, c)
    local piece = self.board[r][c]
    if piece == "w" then return "boardgames/connect4_w" end
    if piece == "b" then return "boardgames/connect4_b" end
    return "boardgames/connect4_empty"
end

function GameHub:buildConnect4Widget(board_width)
    local square_size = math.floor(board_width / CONNECT4_COLS)
    local board_w = square_size * CONNECT4_COLS
    local rows = {}
    for r = 1, CONNECT4_ROWS do
        local row = {}
        for c = 1, CONNECT4_COLS do
            local rr, cc = r, c
            row[#row + 1] = {
                text = nil,
                icon = self:connect4_icon_for_square(rr, cc),
                alpha = true,
                icon_width = square_size,
                icon_height = square_size,
                width = square_size,
                height = square_size,
                background = Blitbuffer.COLOR_WHITE,
                bordersize = 0,
                margin = 0,
                padding = 0,
                padding_h = 0,
                padding_v = 0,
                callback = function() self:on_square_tap(rr, cc) end,
            }
        end
        rows[#rows + 1] = row
    end
    return ButtonTable:new{
        buttons = rows,
        width = board_w,
        shrink_unneeded_width = false,
        zero_sep = true,
        sep_width = 0,
        addVerticalSpan = function() end,
    }, board_w, square_size * CONNECT4_ROWS
end

function GameHub:buildBoardWidget(board_size)
    local square_size = math.floor(board_size / 8)
    board_size = square_size * 8
    local hints = self:current_hints()
    local rows = {}
    for r = 1, 8 do
        local row = {}
        for c = 1, 8 do
            local rr, cc = r, c
            row[#row + 1] = {
                text = nil,
                icon = self:visual_icon_for_square(rr, cc, hints),
                alpha = true,
                icon_width = square_size,
                icon_height = square_size,
                width = square_size,
                height = square_size,
                background = self:square_background_for(rr, cc, hints),
                bordersize = 0,
                margin = 0,
                padding = 0,
                padding_h = 0,
                padding_v = 0,
                callback = function() self:on_square_tap(rr, cc) end,
            }
        end
        rows[#rows + 1] = row
    end
    return ButtonTable:new{
        buttons = rows,
        width = board_size,
        shrink_unneeded_width = false,
        zero_sep = true,
        sep_width = 0,
        addVerticalSpan = function() end,
    }
end

function GameHub:build_layout()
    local top_h = 138
    local bottom_h = 210
    local board_area_h = self.full_height - top_h - bottom_h
    if board_area_h < 400 then
        top_h = 110
        bottom_h = 180
        board_area_h = self.full_height - top_h - bottom_h
    end

    local status = TextWidget:new{
        text = self:status_title(),
        face = Font:getFace("smallinfofont", 20),
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = self.full_width - 20,
    }

    local board
    local board_w
    local board_h
    if self.game_kind == CONNECT4 then
        local cell = math.floor(math.min((self.full_width - 8) / CONNECT4_COLS, board_area_h / CONNECT4_ROWS))
        if cell < 60 then cell = math.floor((self.full_width - 8) / CONNECT4_COLS) end
        board_w = cell * CONNECT4_COLS
        board_h = cell * CONNECT4_ROWS
        board = self:buildConnect4Widget(board_w)
    elseif self.game_kind == TICTACTOE then
        local board_size = math.floor(math.min(self.full_width - 8, board_area_h) / TTT_COLS) * TTT_COLS
        board_w = board_size
        board_h = board_size
        board = self:buildTicTacToeWidget(board_size)
    elseif self.game_kind == MINESWEEPER then
        local cols = (self.minesweeper and self.minesweeper.cols) or MINESWEEPER_COLS
        local board_size = math.floor(math.min(self.full_width, board_area_h) / cols) * cols
        if board_size > self.full_width then
            board_size = math.floor(self.full_width / cols) * cols
        end
        board_w = board_size
        board_h = board_size
        board = self:buildMinesweeperWidget(board_size)
    elseif self.game_kind == BATTLESHIP then
        local cols = (self.battleship and self.battleship.cols) or BATTLESHIP_COLS
        local board_size = math.floor(math.min(self.full_width, board_area_h) / cols) * cols
        if board_size > self.full_width then
            board_size = math.floor(self.full_width / cols) * cols
        end
        board_w = board_size
        board_h = board_size
        board = self:buildBattleshipWidget(board_size)
    else
        local board_size = math.floor(math.min(self.full_width, board_area_h) / 8) * 8
        if board_size > self.full_width then
            board_size = math.floor(self.full_width / 8) * 8
        end
        board_w = board_size
        board_h = board_size
        board = self:buildBoardWidget(board_size)
    end

    local controls = self:buildControlsWidget(self.full_width - 8)

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        VerticalGroup:new{
            CenterContainer:new{ dimen = Geometry:new{ w = self.full_width, h = top_h }, status },
            CenterContainer:new{ dimen = Geometry:new{ w = self.full_width, h = board_area_h }, board },
            CenterContainer:new{ dimen = Geometry:new{ w = self.full_width, h = bottom_h }, controls },
        }
    }
end


function GameHub:show_board()
    logger.dbg("Board Games v1.0.0 show_board")
    ensureBoardGameIconsInstalled()
    self:record_current_result()
    self:build_layout()
    if self._is_open then
        UIManager:setDirty(self, "ui")
    else
        self._is_open = true
        UIManager:show(self)
    end
end



-- ===== TIC TAC TOE PLAY =====

function GameHub:tictactoe_finish_turn()
    local moved_piece = self.turn
    if tictactoe_winner(self.board, moved_piece) then
        self.game_over = true
        self.bot_plan = nil
        if self.mode == HUMAN_VS_BOT then
            if moved_piece == self.human_side then
                self.message = "You win Tic Tac Toe!"
            else
                self.message = "Bot wins Tic Tac Toe."
            end
        else
            self.message = side_label(moved_piece) .. " wins Tic Tac Toe."
        end
        self:show_board()
        return
    end

    if tictactoe_is_full(self.board) then
        self.game_over = true
        self.bot_plan = nil
        self.message = "Draw! Tic Tac Toe board is full."
        self:show_board()
        return
    end

    self.turn = (self.turn == "w") and "b" or "w"

    if self.mode == HUMAN_VS_BOT and self.turn == self.bot_side then
        self:prepare_tictactoe_bot_move()
        return
    end

    self.message = (self.turn == "w" and "White X" or "Black O") .. " to move."
    self:show_board()
end

function GameHub:attempt_tictactoe_move(r, c)
    if self.bot_plan then
        self.message = "Bot is thinking..."
        self:show_board()
        return
    end
    if r < 1 or r > TTT_ROWS or c < 1 or c > TTT_COLS then
        self.message = "Tap inside the Tic Tac Toe board."
        self:show_board()
        return
    end
    if self.board[r][c] ~= "." then
        self.message = "That square is already taken."
        self:show_board()
        return
    end
    self:push_undo_state()
    self.draw_offer = nil
    self.new_game_confirm = false
    self.concede_confirm = false
    self.board[r][c] = self.turn
    self.selected = nil
    self.forced_from = nil
    self:tictactoe_finish_turn()
end

function GameHub:choose_tictactoe_bot_move()
    local moves = tictactoe_list_moves(self.board)
    if #moves == 0 then return nil end
    local ordered = tictactoe_preferred_moves(moves)

    -- Always take an immediate win.
    for _, move in ipairs(ordered) do
        local board = tictactoe_apply_move_clone(self.board, move.r, move.c, self.bot_side)
        if board and tictactoe_winner(board, self.bot_side) then return move end
    end

    -- Easy sometimes misses blocks, but still knows center/corners.
    if self.difficulty_index > 1 then
        for _, move in ipairs(ordered) do
            local board = tictactoe_apply_move_clone(self.board, move.r, move.c, self.human_side)
            if board and tictactoe_winner(board, self.human_side) then return move end
        end
    elseif math.random() <= 0.70 then
        for _, move in ipairs(ordered) do
            local board = tictactoe_apply_move_clone(self.board, move.r, move.c, self.human_side)
            if board and tictactoe_winner(board, self.human_side) then return move end
        end
    end

    if self.difficulty_index == 1 then
        if math.random() <= 0.75 then return ordered[1] or moves[1] end
        return moves[math.random(#moves)]
    end

    if self.difficulty_index == 2 then
        return ordered[1] or moves[1]
    end

    local best_move = ordered[1] or moves[1]
    local best_score = -1000000
    for _, move in ipairs(ordered) do
        local board = tictactoe_apply_move_clone(self.board, move.r, move.c, self.bot_side)
        local score = tictactoe_minimax(board, self.human_side, 0)
        if score > best_score then
            best_score = score
            best_move = move
        end
    end
    return best_move
end

function GameHub:_tictactoe_bot_finish_move(token)
    if token ~= self.bot_anim_token or not self.bot_plan then return end
    local move = self.bot_plan.move
    self.bot_plan = nil
    if not move or self.board[move.r][move.c] ~= "." then
        self.message = "Bot could not move. Your turn."
        self.turn = self.human_side
        self:show_board()
        return
    end
    self.board[move.r][move.c] = self.bot_side
    self:tictactoe_finish_turn()
    if not self.game_over then
        self.message = "Bot moved. Your turn."
        self:show_board()
    end
end

function GameHub:prepare_tictactoe_bot_move()
    local move = self:choose_tictactoe_bot_move()
    if not move then
        self.game_over = true
        self.message = "Draw! Tic Tac Toe board is full."
        self:show_board()
        return
    end
    self:invalidate_bot_animation()
    local token = self.bot_anim_token
    self.bot_plan = { move = move, game = TICTACTOE }
    self.message = "Bot is thinking..."
    self:show_board()
    UIManager:scheduleIn(BOT_DELAY_SECONDS, function() self:_tictactoe_bot_finish_move(token) end)
end

-- ===== CONNECT 4 PLAY =====

function GameHub:connect4_finish_turn(last_col)
    local moved_piece = (self.turn == "w") and "w" or "b"
    if connect4_winner(self.board, moved_piece) then
        self.game_over = true
        self.bot_plan = nil
        if moved_piece == self.human_side then
            self.message = "Game over: You win Connect 4!"
        else
            self.message = "Game over: Bot wins Connect 4."
        end
        if self.mode == HUMAN_VS_HUMAN then
            self.message = "Game over: " .. side_label(moved_piece) .. " wins Connect 4."
        end
        self:show_board()
        return
    end

    if connect4_is_full(self.board) then
        self.game_over = true
        self.bot_plan = nil
        self.message = "Draw! Connect 4 board is full."
        self:show_board()
        return
    end

    self.turn = (self.turn == "w") and "b" or "w"

    if self.mode == HUMAN_VS_BOT and self.turn == self.bot_side then
        self:prepare_connect4_bot_move()
        return
    end

    self.message = (self.turn == "w" and "White" or "Black") .. " to move. Tap a column."
    self:show_board()
end

function GameHub:attempt_connect4_move(col)
    if self.bot_plan then
        self.message = "Bot is thinking..."
        self:show_board()
        return
    end
    local row = connect4_drop_row(self.board, col)
    if not row then
        self.message = "That column is full. Pick another column."
        self:show_board()
        return
    end
    self:push_undo_state()
    self.draw_offer = nil
    self.new_game_confirm = false
    self.board[row][col] = self.turn
    self.selected = nil
    self.forced_from = nil
    self:connect4_finish_turn(col)
end

function GameHub:choose_connect4_bot_move()
    local moves = connect4_list_moves(self.board)
    if #moves == 0 then return nil end

    local preferred = { 4, 3, 5, 2, 6, 1, 7 }
    local easy_can_miss_block = self.difficulty_index == 1 and math.random() < 0.30

    local function ordered_moves(list)
        local result = {}
        for _, col in ipairs(preferred) do
            for _, candidate in ipairs(list) do
                if candidate == col then
                    result[#result + 1] = col
                    break
                end
            end
        end
        return result
    end

    local function first_center_available(list)
        local ordered = ordered_moves(list)
        return ordered[1]
    end

    -- Always take a win, even on Easy.
    for _, col in ipairs(ordered_moves(moves)) do
        local board = connect4_apply_move_clone(self.board, col, self.bot_side)
        if board and connect4_winner(board, self.bot_side) then return col end
    end

    -- Easy occasionally misses blocks, while Medium/Hard defend consistently.
    if not easy_can_miss_block then
        for _, col in ipairs(ordered_moves(moves)) do
            local board = connect4_apply_move_clone(self.board, col, self.human_side)
            if board and connect4_winner(board, self.human_side) then return col end
        end
    end

    -- Avoid moves that hand the player an immediate win next turn.
    local safe = {}
    for _, col in ipairs(moves) do
        local board = connect4_apply_move_clone(self.board, col, self.bot_side)
        local dangerous = false
        if board then
            local reply_moves = connect4_list_moves(board)
            for _, reply_col in ipairs(reply_moves) do
                local reply_board = connect4_apply_move_clone(board, reply_col, self.human_side)
                if reply_board and connect4_winner(reply_board, self.human_side) then
                    dangerous = true
                    break
                end
            end
        end
        if not dangerous then safe[#safe + 1] = col end
    end
    if #safe == 0 then safe = moves end

    if self.difficulty_index == 1 then
        -- Easy is still imperfect, but no longer completely careless.
        if math.random() <= 0.85 then
            return first_center_available(safe) or safe[math.random(#safe)]
        end
        return safe[math.random(#safe)]
    end

    local best_col = first_center_available(safe) or safe[1]
    local best_score = -1000000
    local depth = self.difficulty_index == 2 and 4 or 5

    for _, col in ipairs(ordered_moves(safe)) do
        local board = connect4_apply_move_clone(self.board, col, self.bot_side)
        local score = connect4_minimax(board, self.human_side, depth - 1, -1000000, 1000000)
        -- slight center preference as a tie-breaker
        score = score - math.abs(4 - col)
        if score > best_score then
            best_score = score
            best_col = col
        end
    end

    return best_col
end

function GameHub:_connect4_bot_finish_move(token)
    if token ~= self.bot_anim_token or not self.bot_plan then return end
    local col = self.bot_plan.move
    self.bot_plan = nil
    local row = connect4_drop_row(self.board, col)
    if not row then
        self.message = "Bot could not move. Your turn."
        self.turn = self.human_side
        self:show_board()
        return
    end
    self.board[row][col] = self.bot_side
    self:connect4_finish_turn(col)
    if not self.game_over then
        self.message = "Bot dropped in column " .. tostring(col) .. ". Your turn."
        self:show_board()
    end
end

function GameHub:prepare_connect4_bot_move()
    local move = self:choose_connect4_bot_move()
    if not move then
        self.game_over = true
        self.message = "Draw! Connect 4 board is full."
        self:show_board()
        return
    end
    self:invalidate_bot_animation()
    local token = self.bot_anim_token
    self.bot_plan = { move = move, game = CONNECT4 }
    self.message = "Bot is thinking..."
    self:show_board()
    UIManager:scheduleIn(BOT_DELAY_SECONDS, function() self:_connect4_bot_finish_move(token) end)
end

-- ===== CHECKERS BOT =====

function GameHub:choose_checkers_bot_move()
    local moves = checkers_list_legal_moves(self.board, self.bot_side)
    if #moves == 0 then return nil end
    if self.difficulty_index == 1 then
        return moves[math.random(#moves)]
    end
    local white_count, black_count = checkers_count_pieces(self.board)
    local total = white_count + black_count
    local depth = self.difficulty_index == 2 and 3 or 4
    if self.difficulty_index == 3 and total <= 8 then depth = 5 end

    local best_value = -1000000
    local best_move = moves[1]
    for _, move in ipairs(moves) do
        local value = checkers_minimax(move.board, self.human_side, depth - 1, -1000000, 1000000)
        if value > best_value then
            best_value = value
            best_move = move
        end
    end
    return best_move
end

function GameHub:_checkers_bot_finish_move(token)
    if token ~= self.bot_anim_token or not self.bot_plan then return end
    local move = self.bot_plan.move
    local moving_piece = self.board[move.from_r][move.from_c]
    local bot_promoted = (moving_piece == "b" and move.to_r == 8) or (moving_piece == "w" and move.to_r == 1)
    local bot_capture = move.is_capture == true
    self.board = clone_board(move.board)
    self.selected = nil
    self.forced_from = nil
    self.bot_plan = nil
    self.turn = self.human_side

    local white_count, black_count = checkers_count_pieces(self.board)
    if white_count == 0 then
        self.game_over = true
        self.message = "Game over: Black wins."
        self:show_board()
        return
    end
    if black_count == 0 then
        self.game_over = true
        self.message = "Game over: White wins."
        self:show_board()
        return
    end

    self:update_checkers_draw_counter(bot_capture, bot_promoted)
    if self:check_checkers_draw() then return end

    if not checkers_any_move_for_turn(self.board, self.turn) then
        self.game_over = true
        self.message = "Game over: Black wins. White has no legal moves."
        self:show_board()
        return
    end
    self.message = "Bot moved " .. move_label(move) .. ". Your turn."
    if bot_capture then
        self.message = self.message .. " Capture."
    end
    if bot_promoted then
        self.message = self.message .. " Kinged."
    end
    self:show_board()
end

function GameHub:prepare_checkers_bot_move()
    local move = self:choose_checkers_bot_move()
    if not move then
        self.game_over = true
        self.message = "Game over: White wins. Black has no legal moves."
        self:show_board()
        return
    end
    self:invalidate_bot_animation()
    local token = self.bot_anim_token
    self.bot_plan = { move = move, game = CHECKERS }
    self.message = "Bot is thinking..."
    self:show_board()
    UIManager:scheduleIn(BOT_DELAY_SECONDS, function() self:_checkers_bot_finish_move(token) end)
end

-- ===== CHESS BOT =====

local CHESS_VALUES = { p = 100, n = 320, b = 330, r = 500, q = 900, k = 20000 }

local function chess_evaluate_board(board)
    local score = 0
    for r = 1, 8 do
        for c = 1, 8 do
            local p = board[r][c]
            if p ~= "." then
                local lower = p:lower()
                local value = CHESS_VALUES[lower] or 0
                local center_bonus = 0
                if lower ~= "k" then
                    local dr = math.abs(4.5 - r)
                    local dc = math.abs(4.5 - c)
                    center_bonus = math.floor((4 - dr) + (4 - dc))
                    if center_bonus < 0 then center_bonus = 0 end
                end
                if chess_owner(p) == "b" then
                    score = score + value + center_bonus
                else
                    score = score - value - center_bonus
                end
            end
        end
    end
    return score
end

local function chess_minimax(board, turn, depth, alpha, beta)
    local moves = chess_generate_legal_moves(board, turn)
    if #moves == 0 then
        if chess_is_in_check(board, turn) then
            return turn == "b" and -100000 or 100000
        end
        return 0
    end
    if depth <= 0 then
        return chess_evaluate_board(board)
    end

    if turn == "b" then
        local best = -1000000
        for _, move in ipairs(moves) do
            local value = chess_minimax(move.board, "w", depth - 1, alpha, beta)
            if value > best then best = value end
            if value > alpha then alpha = value end
            if beta <= alpha then break end
        end
        return best
    else
        local best = 1000000
        for _, move in ipairs(moves) do
            local value = chess_minimax(move.board, "b", depth - 1, alpha, beta)
            if value < best then best = value end
            if value < beta then beta = value end
            if beta <= alpha then break end
        end
        return best
    end
end

function GameHub:choose_chess_bot_move()
    local moves = chess_generate_legal_moves(self.board, self.bot_side)
    if #moves == 0 then return nil end

    if self.difficulty_index == 1 then
        return moves[math.random(#moves)]
    end

    local white_count, black_count = chess_count_pieces(self.board)
    local total = white_count + black_count
    local search_depth = self.difficulty_index == 2 and 1 or 2
    if self.difficulty_index == 3 and total <= 8 then
        search_depth = 3
    end

    local best_value = -1000000
    local best_move = moves[1]
    for _, move in ipairs(moves) do
        local value
        if self.difficulty_index == 2 then
            value = chess_evaluate_board(move.board)
        else
            value = chess_minimax(move.board, self.human_side, search_depth - 1, -1000000, 1000000)
        end
        if value > best_value then
            best_value = value
            best_move = move
        end
    end
    return best_move
end

function GameHub:_chess_bot_finish_move(token)
    if token ~= self.bot_anim_token or not self.bot_plan then return end
    local move = self.bot_plan.move
    local moving_piece = self.board[move.from_r][move.from_c]
    local captured_piece = self.board[move.to_r][move.to_c]
    if move.en_passant_capture_r and move.en_passant_capture_c then
        captured_piece = self.board[move.en_passant_capture_r][move.en_passant_capture_c]
    end
    self:update_chess_castling_rights(move, moving_piece, captured_piece)
    self.board = clone_board(move.board)
    if CHESS_EN_PASSANT_ENABLED and moving_piece and moving_piece:lower() == "p" and math.abs(move.to_r - move.from_r) == 2 then
        CHESS_EN_PASSANT = {
            turn = self.turn,
            target_r = math.floor((move.from_r + move.to_r) / 2),
            target_c = move.from_c,
            capture_r = move.to_r,
            capture_c = move.from_c,
        }
    else
        CHESS_EN_PASSANT = nil
    end
    self.selected = nil
    self.forced_from = nil
    self.bot_plan = nil
    self.turn = self.human_side

    local legal = chess_generate_legal_moves(self.board, self.turn)
    local in_check = chess_is_in_check(self.board, self.turn)
    if #legal == 0 then
        self.game_over = true
        if in_check then
            self.message = "Checkmate. Bot wins."
        else
            self.message = "Stalemate. Game drawn."
        end
        self:show_board()
        return
    end

    self.message = "Bot moved " .. move_label(move) .. ". Your turn."
    if in_check then
        self.message = self.message .. " You are in check."
    end
    self:show_board()
end

function GameHub:prepare_chess_bot_move()
    local move = self:choose_chess_bot_move()
    if not move then
        local in_check = chess_is_in_check(self.board, self.bot_side)
        self.game_over = true
        if in_check then
            self.message = "Checkmate. White wins."
        else
            self.message = "Stalemate. Game drawn."
        end
        self:show_board()
        return
    end
    self:invalidate_bot_animation()
    local token = self.bot_anim_token
    self.bot_plan = { move = move, game = CHESS }
    self.message = "Bot is thinking..."
    self:show_board()
    UIManager:scheduleIn(BOT_DELAY_SECONDS, function() self:_chess_bot_finish_move(token) end)
end

-- ===== CHECKERS PLAY =====

function GameHub:apply_checkers_move(r1, c1, r2, c2, is_capture, capr, capc)
    local piece = self.board[r1][c1]
    self.board[r1][c1] = "."
    if is_capture then self.board[capr][capc] = "." end
    local promoted = false
    if piece == "w" and r2 == 1 then piece = "W"; promoted = true end
    if piece == "b" and r2 == 8 then piece = "B"; promoted = true end
    self.board[r2][c2] = piece
    return promoted
end

function GameHub:update_checkers_draw_counter(is_capture, promoted)
    if is_capture or promoted then
        self.checkers_no_progress = 0
    else
        self.checkers_no_progress = (self.checkers_no_progress or 0) + 1
    end
end

function GameHub:check_checkers_draw()
    if checkers_only_two_kings_left(self.board) then
        self.game_over = true
        self.selected = nil
        self.forced_from = nil
        self:invalidate_bot_animation()
        self.message = "Draw! Only one king remains for each side."
        self:show_board()
        return true
    end
    if (self.checkers_no_progress or 0) >= (CHECKERS_DRAW_LIMITS[self.checkers_draw_index or 3] or 80) then
        self.game_over = true
        self.selected = nil
        self.forced_from = nil
        self:invalidate_bot_animation()
        self.message = "Draw! No capture or kinging within the selected draw limit."
        self:show_board()
        return true
    end
    return false
end

function GameHub:finish_checkers_turn(r2, c2, is_capture, promoted)
    local white_count, black_count = checkers_count_pieces(self.board)
    if white_count == 0 then
        self.game_over = true
        self.selected = nil
        self.forced_from = nil
        self:invalidate_bot_animation()
        self.message = "Game over: Black wins."
        self:show_board()
        return
    end
    if black_count == 0 then
        self.game_over = true
        self.selected = nil
        self.forced_from = nil
        self:invalidate_bot_animation()
        self.message = "Game over: White wins."
        self:show_board()
        return
    end

    self:update_checkers_draw_counter(is_capture, promoted)
    if self:check_checkers_draw() then return end

    if is_capture and not promoted and checkers_piece_has_capture(self.board, r2, c2) then
        self.selected = { r2, c2 }
        self.forced_from = { r2, c2 }
        self.message = side_label(self.turn) .. " must jump again."
        self:show_board()
        return
    end

    self.selected = nil
    self.forced_from = nil
    self.turn = (self.turn == "w") and "b" or "w"

    if not checkers_any_move_for_turn(self.board, self.turn) then
        self.game_over = true
        self.message = (self.turn == "w") and "Game over: Black wins. White has no legal moves." or "Game over: White wins. Black has no legal moves."
        self:show_board()
        return
    end

    if self.mode == HUMAN_VS_BOT and self.turn == self.bot_side then
        self:prepare_checkers_bot_move()
        return
    end

    self.message = side_label(self.turn) .. " to move."
    self:show_board()
end


function GameHub:count_destination_set(destinations)
    local count = 0
    local only_r, only_c = nil, nil
    for key in pairs(destinations) do
        count = count + 1
        local r, c = key:match("^(%d+):(%d+)$")
        only_r, only_c = tonumber(r), tonumber(c)
    end
    return count, only_r, only_c
end

function GameHub:smart_move_enabled()
    return false
end

function GameHub:select_checkers_piece(r, c)
    local piece = self.board[r][c]
    if checkers_owner(piece) ~= self.turn then
        self.message = piece == "." and "Tap one of your pieces first." or "That is not your piece."
        self:show_board()
        return
    end
    if self.mode == HUMAN_VS_BOT and self.turn ~= self.human_side then
        self.message = "Bot is moving..."
        self:show_board()
        return
    end
    if self.forced_from and (r ~= self.forced_from[1] or c ~= self.forced_from[2]) then
        self.selected = { self.forced_from[1], self.forced_from[2] }
        self.message = "You must continue jumping from " .. square_name(self.forced_from[1], self.forced_from[2]) .. "."
        self:show_board()
        return
    end
    if CHECKERS_FORCE_CAPTURE and checkers_any_capture_for_turn(self.board, self.turn) and not checkers_piece_has_capture(self.board, r, c) then
        self.selected = nil
        self.message = "A capture is available. Pick a piece that can jump."
        self:show_board()
        return
    end
    if not checkers_piece_has_capture(self.board, r, c) and not checkers_piece_has_simple_move(self.board, r, c) then
        self.selected = nil
        self.message = "That piece has no legal moves."
        self:show_board()
        return
    end

    local destinations = checkers_destination_set(self.board, self.turn, r, c, self.forced_from)
    local count, only_r, only_c = self:count_destination_set(destinations)
    if self:smart_move_enabled() and count == 1 and only_r and only_c then
        local ok, is_capture, capr, capc = checkers_validate_move(self.board, self.turn, r, c, only_r, only_c, self.forced_from)
        if ok then
            local promoted = self:apply_checkers_move(r, c, only_r, only_c, is_capture, capr, capc)
            self.message = "Moved " .. square_name(r, c) .. " to " .. square_name(only_r, only_c) .. "."
            self:finish_checkers_turn(only_r, only_c, is_capture, promoted)
            return
        end
    end

    self.selected = { r, c }
    self.message = count > 1 and "Tap a highlighted destination." or "Tap a highlighted destination square."
    self:show_board()
end

function GameHub:attempt_checkers_move(r2, c2)
    if self.bot_plan then
        self.message = "Bot is moving..."
        self:show_board()
        return
    end
    if not self.selected then
        self:select_checkers_piece(r2, c2)
        return
    end
    local r1, c1 = self.selected[1], self.selected[2]
    if r1 == r2 and c1 == c2 then
        self.selected = self.forced_from and { self.forced_from[1], self.forced_from[2] } or nil
        self.message = self.forced_from and ("Continue jumping from " .. square_name(self.forced_from[1], self.forced_from[2]) .. ".") or "Selection cleared."
        self:show_board()
        return
    end
    if checkers_owner(self.board[r2][c2]) == self.turn then
        self:select_checkers_piece(r2, c2)
        return
    end
    local ok, is_capture, capr, capc = checkers_validate_move(self.board, self.turn, r1, c1, r2, c2, self.forced_from)
    if not ok then
        self.message = is_capture
        self:show_board()
        return
    end
    self:push_undo_state()
    self.draw_offer = nil
    self.new_game_confirm = false
    local promoted = self:apply_checkers_move(r1, c1, r2, c2, is_capture, capr, capc)
    self:finish_checkers_turn(r2, c2, is_capture, promoted)
end

-- ===== CHESS PLAY =====

function GameHub:select_chess_piece(r, c)
    local piece = self.board[r][c]
    if chess_owner(piece) ~= self.turn then
        self.message = piece == "." and "Tap one of your pieces first." or "That is not your piece."
        self:show_board()
        return
    end
    if self.mode == HUMAN_VS_BOT and self.turn ~= self.human_side then
        self.message = "Bot is moving..."
        self:show_board()
        return
    end
    local hints = chess_destination_set(self.board, self.turn, r, c)
    local count, only_r, only_c = self:count_destination_set(hints)
    if count == 0 then
        if chess_is_in_check(self.board, self.turn) then
            self.message = "That move will not help with check. Pick a legal move that protects your king."
        else
            self.message = "That piece is blocked right now. Try a pawn, knight, or move another piece first."
        end
        self.selected = nil
        self:show_board()
        return
    end

    if self:smart_move_enabled() and count == 1 and only_r and only_c then
        local move = chess_find_move(self.board, self.turn, r, c, only_r, only_c)
        if move then
            self.board = clone_board(move.board)
            self.message = "Moved " .. square_name(r, c) .. " to " .. square_name(only_r, only_c) .. "."
            self:finish_chess_turn(move)
            return
        end
    end

    self.selected = { r, c }
    self.message = count > 1 and "Tap a highlighted destination." or "Tap a highlighted destination square."
    self:show_board()
end

function GameHub:finish_chess_turn(last_move)
    self.selected = nil
    self.turn = (self.turn == "w") and "b" or "w"
    local legal = chess_generate_legal_moves(self.board, self.turn)
    local in_check = chess_is_in_check(self.board, self.turn)

    if #legal == 0 then
        self.game_over = true
        if in_check then
            self.message = (self.turn == "w") and "Checkmate. Black wins." or "Checkmate. White wins."
        else
            self.message = "Stalemate. Game drawn."
        end
        self:show_board()
        return
    end

    if self.mode == HUMAN_VS_BOT and self.turn == self.bot_side then
        self:prepare_chess_bot_move()
        return
    end

    if in_check then
        self.message = side_label(self.turn) .. " to move and in check."
    else
        self.message = side_label(self.turn) .. " to move."
    end
    if last_move and (self.board[last_move.to_r][last_move.to_c] == "Q" or self.board[last_move.to_r][last_move.to_c] == "q") then
        local moved_piece = self.board[last_move.to_r][last_move.to_c]
        if (last_move.from_r == 7 and moved_piece == "Q") or (last_move.from_r == 2 and moved_piece == "q") then
            self.message = self.message .. " Pawn promoted to queen."
        end
    end
    self:show_board()
end

function GameHub:attempt_chess_move(r2, c2)
    if self.bot_plan then
        self.message = "Bot is moving..."
        self:show_board()
        return
    end
    if not self.selected then
        self:select_chess_piece(r2, c2)
        return
    end
    local r1, c1 = self.selected[1], self.selected[2]
    if r1 == r2 and c1 == c2 then
        self.selected = nil
        self.message = "Selection cleared."
        self:show_board()
        return
    end
    if chess_owner(self.board[r2][c2]) == self.turn then
        self:select_chess_piece(r2, c2)
        return
    end
    local move = chess_find_move(self.board, self.turn, r1, c1, r2, c2)
    if not move then
        self.message = "Illegal chess move. Tap one of the highlighted destination squares."
        self:show_board()
        return
    end
    self:push_undo_state()
    self.draw_offer = nil
    self.new_game_confirm = false
    local moving_piece = self.board[r1][c1]
    local captured_piece = self.board[r2][c2]
    if move.en_passant_capture_r and move.en_passant_capture_c then
        captured_piece = self.board[move.en_passant_capture_r][move.en_passant_capture_c]
    end
    self:update_chess_castling_rights(move, moving_piece, captured_piece)
    self.board = clone_board(move.board)
    if CHESS_EN_PASSANT_ENABLED and moving_piece and moving_piece:lower() == "p" and math.abs(r2 - r1) == 2 then
        CHESS_EN_PASSANT = {
            turn = self.turn,
            target_r = math.floor((r1 + r2) / 2),
            target_c = c1,
            capture_r = r2,
            capture_c = c1,
        }
    else
        CHESS_EN_PASSANT = nil
    end
    self:finish_chess_turn(move)
end

function GameHub:attempt_minesweeper_tap(r, c)
    local state = self.minesweeper
    if not state then
        state = fresh_minesweeper_state(MINESWEEPER_MINE_COUNTS[self.difficulty_index] or MINESWEEPER_MINE_COUNTS[2])
        self.minesweeper = state
    end
    if r < 1 or r > state.rows or c < 1 or c > state.cols then return end

    if self.minesweeper_flag_mode then
        if state.revealed[r][c] then
            self.message = "That square is already revealed."
            self:show_board()
            return
        end
        self:push_undo_state()
        state.flagged[r][c] = not state.flagged[r][c]
        state.flags = (state.flags or 0) + (state.flagged[r][c] and 1 or -1)
        local flags_left = (state.mines or 0) - (state.flags or 0)
        self.message = (state.flagged[r][c] and "Flag placed. " or "Flag removed. ") .. tostring(flags_left) .. " flags left."
        self:show_board()
        return
    end

    if state.flagged[r][c] then
        self.message = "That square is flagged. Switch to Flag mode to unmark it."
        self:show_board()
        return
    end
    if state.revealed[r][c] then
        local adjacent = minesweeper_adjacent_count(state, r, c)
        local flags = 0
        minesweeper_each_neighbor(state, r, c, function(nr, nc)
            if state.flagged[nr][nc] then flags = flags + 1 end
        end)
        if adjacent > 0 and flags == adjacent then
            self:push_undo_state()
            local revealed = 0
            local hit_mine = false
            minesweeper_each_neighbor(state, r, c, function(nr, nc)
                if not state.revealed[nr][nc] and not state.flagged[nr][nc] then
                    if state.mined[nr][nc] then
                        state.revealed[nr][nc] = true
                        hit_mine = true
                    else
                        revealed = revealed + minesweeper_reveal_cell(state, nr, nc)
                    end
                end
            end)
            if hit_mine then
                self.game_over = true
                self.message = "Boom! A nearby mine was unflagged."
            elseif (state.revealed_count or 0) >= ((state.rows * state.cols) - state.mines) then
                self.game_over = true
                self.message = "Cleared! You win Minesweeper."
            else
                self.message = revealed > 0 and ("Cleared " .. tostring(revealed) .. " nearby squares.") or "No nearby squares to clear."
            end
            self:show_board()
            return
        end
        self.message = adjacent > 0 and ("Need " .. tostring(adjacent) .. " flags nearby to auto-clear.") or "That square is already clear."
        self:show_board()
        return
    end

    self:push_undo_state()
    local was_first_reveal = not state.first_reveal_done
    minesweeper_protect_first_reveal(state, r, c)
    if state.mined[r][c] then
        state.revealed[r][c] = true
        self.game_over = true
        self.message = "Boom! Mine hit."
        self:show_board()
        return
    end

    local count = minesweeper_reveal_cell(state, r, c)
    local safe_total = (state.rows * state.cols) - state.mines
    if (state.revealed_count or 0) >= safe_total then
        self.game_over = true
        self.message = "Cleared! You win Minesweeper."
    elseif count > 1 then
        self.message = (was_first_reveal and "First click protected. " or "") .. "Cleared " .. tostring(count) .. " safe squares."
    else
        local adjacent = minesweeper_adjacent_count(state, r, c)
        local prefix = was_first_reveal and "First click protected. " or ""
        self.message = prefix .. (adjacent == 0 and "Safe." or ("Safe. " .. tostring(adjacent) .. " nearby."))
    end
    self:show_board()
end

function GameHub:battleship_bot_fire()
    local state = self.battleship
    if not state then return nil end
    state.player_sunk = state.player_sunk or {}
    local target
    if self.difficulty_index == 3 then
        target = battleship_line_target(state) or battleship_hunt_target(state)
    elseif self.difficulty_index == 2 and math.random(2) == 1 then
        target = battleship_line_target(state) or battleship_hunt_target(state)
    end
    target = target or battleship_random_unshot(state.bot_shots)
    if not target then return nil end
    state.bot_shots[target.r][target.c] = true
    local hit = state.player_ships[target.r][target.c]
    local sunk = false
    local ship_id = state.player_ship_ids and state.player_ship_ids[target.r][target.c] or 0
    if hit then
        state.bot_hits = (state.bot_hits or 0) + 1
        if not state.player_sunk[ship_id] and battleship_is_ship_sunk(state.player_ship_ids, state.bot_shots, ship_id) then
            state.player_sunk[ship_id] = true
            sunk = true
        end
    end
    return {
        r = target.r,
        c = target.c,
        hit = hit,
        sunk = sunk,
        ship_name = battleship_ship_name(ship_id),
        length = state.player_ship_lengths and state.player_ship_lengths[ship_id] or nil,
    }
end

function GameHub:attempt_battleship_fire(r, c)
    local state = self.battleship
    if not state then
        state = fresh_battleship_state()
        self.battleship = state
    end
    if state.phase == "setup" then
        local ship_id = state.placing_ship or 1
        local length = BATTLESHIP_SHIPS[ship_id]
        if not length then
            state.phase = "battle"
            state.view = "enemy"
            self.message = "Fleet ready. Fire at enemy waters."
            self:show_board()
            return
        end
        local horizontal = state.place_horizontal ~= false
        if not battleship_can_place(state.player_ships, r, c, length, horizontal) then
            local dir = horizontal and "horizontally" or "vertically"
            self.message = "That " .. battleship_ship_name(ship_id) .. " will not fit " .. dir .. " there."
            self:show_board()
            return
        end
        self:push_undo_state()
        battleship_place_ship(state.player_ships, state.player_ship_ids, ship_id, r, c, length, horizontal)
        state.player_ship_lengths[ship_id] = length
        state.placing_ship = ship_id + 1
        if state.placing_ship > #BATTLESHIP_SHIPS then
            state.phase = "battle"
            state.view = "enemy"
            self.message = "Fleet ready. Battle started. Fire at enemy waters."
        else
            local dir = state.place_horizontal ~= false and "horizontal" or "vertical"
            self.message = "Placed " .. battleship_ship_name(ship_id) .. ". Place " .. battleship_ship_name(state.placing_ship) .. " " .. dir .. "."
        end
        self:show_board()
        return
    end
    if state.view == "fleet" then
        self.message = "Viewing your fleet. Switch to Enemy Waters to fire."
        self:show_board()
        return
    end
    if state.player_shots[r][c] then
        self.message = "You already fired there."
        self:show_board()
        return
    end

    self:push_undo_state()
    state.bot_sunk = state.bot_sunk or {}
    state.player_shots[r][c] = true
    local player_hit = state.bot_ships[r][c]
    local player_sunk = false
    local ship_id = state.bot_ship_ids and state.bot_ship_ids[r][c] or 0
    if player_hit then
        state.player_hits = (state.player_hits or 0) + 1
        if not state.bot_sunk[ship_id] and battleship_is_ship_sunk(state.bot_ship_ids, state.player_shots, ship_id) then
            state.bot_sunk[ship_id] = true
            player_sunk = true
        end
    end
    if (state.player_hits or 0) >= (state.total_ship_cells or battleship_ship_cell_count()) then
        self.game_over = true
        self.message = "Hit! You sank the enemy fleet."
        self:show_board()
        return
    end

    local bot = self:battleship_bot_fire()
    if bot and (state.bot_hits or 0) >= (state.total_ship_cells or battleship_ship_cell_count()) then
        self.game_over = true
        state.view = "fleet"
        self.message = (player_hit and "Hit. " or "Miss. ") .. "Bot sank your fleet."
        self:show_board()
        return
    end

    local player_text
    if player_sunk then
        player_text = "Hit. You sank the enemy " .. battleship_ship_name(ship_id) .. "."
    else
        player_text = player_hit and "Hit." or "Miss."
    end
    local bot_text = ""
    if bot then
        if bot.sunk then
            bot_text = " Bot sank your " .. bot.ship_name .. "."
        elseif bot.hit then
            bot_text = " Bot hit your ship."
        else
            bot_text = " Bot missed."
        end
    end
    self.message = player_text .. bot_text
    self:show_board()
end

function GameHub:on_square_tap(r, c)
    self.new_game_confirm = false
    self.concede_confirm = false
    if self.game_over then
        self.message = "Game over. Start a new game to play again."
        self:show_board()
        return
    end
    if self.game_kind == CHECKERS then
        if self.mode == HUMAN_VS_BOT and self.turn == self.bot_side then
            self.message = "Bot is moving..."
            self:show_board()
            return
        end
        self:attempt_checkers_move(r, c)
    elseif self.game_kind == CONNECT4 then
        if self.mode == HUMAN_VS_BOT and self.turn == self.bot_side then
            self.message = "Bot is thinking..."
            self:show_board()
            return
        end
        self:attempt_connect4_move(c)
    elseif self.game_kind == TICTACTOE then
        if self.mode == HUMAN_VS_BOT and self.turn == self.bot_side then
            self.message = "Bot is thinking..."
            self:show_board()
            return
        end
        self:attempt_tictactoe_move(r, c)
    elseif self.game_kind == MINESWEEPER then
        self:attempt_minesweeper_tap(r, c)
    elseif self.game_kind == BATTLESHIP then
        self:attempt_battleship_fire(r, c)
    else
        if self.mode == HUMAN_VS_BOT and self.turn == self.bot_side then
            self.message = "Bot is moving..."
            self:show_board()
            return
        end
        self:attempt_chess_move(r, c)
    end
end

function GameHub:onBoardGamesOpen()
    self:show_board()
end

return GameHub


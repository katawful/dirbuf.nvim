local uv = vim.loop

local errorf = require("dirbuf.utils").errorf

local M = {}

local FNV_PRIME = 16777619
local FNV_OFFSET_BASIS = 2166136261

-- We use 4 byte hashes
M.HASH_LEN = 8
local HASH_MAX = 256 * 256 * 256 * 256

-- 32 bit FNV-1a hash that is cut to the least significant 3 bytes.
local function hash(str)
  local h = FNV_OFFSET_BASIS
  for c in str:gmatch(".") do
    h = bit.bxor(h, c:byte())
    h = h * FNV_PRIME
  end
  return string.format("%08x", h % HASH_MAX)
end

M.FState = {}
local FState = M.FState

function FState.new(fname, ftype)
  local o = {fname = fname, ftype = ftype}
  setmetatable(o, {__index = FState})
  return o
end

-- TODO: Do all classifiers from here
-- https://unix.stackexchange.com/questions/82357/what-do-the-symbols-displayed-by-ls-f-mean#82358
-- with types from
-- https://github.com/tbastos/luv/blob/2fed9454ebb870548cef1081a1f8a3dd879c1e70/src/fs.c#L420-L430
function FState.from_dispname(dispname)
  -- This is the last byte as a string, which is okay because all our
  -- identifiers are single characters
  local last_char = dispname:sub(-1, -1)
  if last_char == "/" then
    return FState.new(dispname:sub(0, -2), "directory")
  elseif last_char == "@" then
    return FState.new(dispname:sub(0, -2), "link")
  elseif last_char == "=" then
    return FState.new(dispname:sub(0, -2), "socket")
  elseif last_char == "|" then
    return FState.new(dispname:sub(0, -2), "fifo")
  else
    return FState.new(dispname, "file")
  end
end

function FState:dispname()
  if self.ftype == "file" then
    return self.fname
  elseif self.ftype == "directory" then
    return self.fname .. "/"
  elseif self.ftype == "link" then
    return self.fname .. "@"
  elseif self.ftype == "socket" then
    return self.fname .. "="
  elseif self.ftype == "fifo" then
    return self.fname .. "|"
  else
    -- Should I just assume it's a file??
    errorf("unrecognized ftype %s", vim.inspect(self.ftype))
  end
end

function FState:hash()
  return hash(self.fname)
end

-- Directories have to be executable for you to chdir into them
M.actions = {}
local DEFAULT_FILE_MODE = tonumber("644", 8)
local DEFAULT_DIR_MODE = tonumber("755", 8)
function M.actions.create(args)
  local fstate = args.fstate

  -- TODO: This is a TOCTOU
  if uv.fs_access(fstate.fname, "W") then
    errorf("%s at '%s' already exists", fstate.ftype, fstate.fname)
  end

  local ok
  if fstate.ftype == "file" then
    -- append instead of write to be non-destructive
    ok = uv.fs_open(fstate.fname, "a", DEFAULT_FILE_MODE)
  elseif fstate.ftype == "directory" then
    ok = uv.fs_mkdir(fstate.fname, DEFAULT_DIR_MODE)
  else
    errorf("unsupported ftype: %s", fstate.ftype)
  end

  if not ok then
    errorf("create failed: %s", fstate.fname)
  end
end

function M.actions.copy(args)
  local old_fname, new_fname = args.old_fname, args.new_fname
  -- TODO: Support copying directories. Needs keeping around fstates
  local ok = uv.fs_copyfile(old_fname, new_fname, nil)
  if not ok then
    errorf("copy failed: %s -> %s", old_fname, new_fname)
  end
end

-- TODO: Use err instead of return
local function rm(fname, ftype)
  if ftype == "file" or ftype == "symlink" then
    return uv.fs_unlink(fname)

  elseif ftype == "directory" then
    local handle = uv.fs_scandir(fname)
    while true do
      local new_fname, new_ftype = uv.fs_scandir_next(handle)
      if new_fname == nil then
        break
      end
      local ok, err, name = rm(fname .. "/" .. new_fname, new_ftype)
      if not ok then
        return ok, err, name
      end
    end
    return uv.fs_rmdir(fname)
  else
    return false, "unrecognized ftype", "dirbuf_internal"
  end
end

function M.actions.delete(args)
  local fstate = args.fstate
  local ok, err, _ = rm(fstate.fname, fstate.ftype)
  if not ok then
    errorf("delete failed: %s", err)
  end
end

function M.actions.move(args)
  local old_fname, new_fname = args.old_fname, args.new_fname
  -- TODO: This is a TOCTOU
  if uv.fs_access(new_fname, "W") then
    errorf("file at '%s' already exists", new_fname)
  end
  local ok = uv.fs_rename(old_fname, new_fname)
  if not ok then
    errorf("move failed: %s -> %s", old_fname, new_fname)
  end
end

return M

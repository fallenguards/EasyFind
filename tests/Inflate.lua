-- Base64 and raw deflate (RFC 1951) decoding for tests: in the game the
-- client unpacks the GPS walking data itself (C_EncodingUtil).
local Inflate = {}
local unpack = rawget(table, "unpack") or unpack

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local dec = {}
for i = 1, 64 do dec[B64:byte(i)] = i - 1 end

function Inflate.DecodeBase64(s)
    local out, n = {}, 0
    for i = 1, #s - 3, 4 do
        local a, b, c, d = dec[s:byte(i)], dec[s:byte(i + 1)], dec[s:byte(i + 2)], dec[s:byte(i + 3)]
        local v = a * 262144 + b * 4096 + (c or 0) * 64 + (d or 0)
        n = n + 1
        out[n] = string.char(math.floor(v / 65536) % 256)
        if c then n = n + 1; out[n] = string.char(math.floor(v / 256) % 256) end
        if d then n = n + 1; out[n] = string.char(v % 256) end
    end
    return table.concat(out)
end

local LEN_BASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEN_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DIST_BASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                    4097, 6145, 8193, 12289, 16385, 24577 }
local DIST_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local CL_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

-- Canonical Huffman codes from code lengths: (length, code) -> symbol.
local function Codes(lengths, n)
    local count = {}
    for l = 0, 15 do count[l] = 0 end
    for sym = 0, n - 1 do
        local l = lengths[sym] or 0
        count[l] = count[l] + 1
    end
    count[0] = 0
    local nextCode, code = {}, 0
    for l = 1, 15 do
        code = (code + count[l - 1]) * 2
        nextCode[l] = code
    end
    local map = {}
    for sym = 0, n - 1 do
        local l = lengths[sym] or 0
        if l > 0 then
            map[l * 65536 + nextCode[l]] = sym
            nextCode[l] = nextCode[l] + 1
        end
    end
    return map
end

function Inflate.Raw(s)
    local pos, bitbuf, bitcnt = 1, 0, 0
    local out, n = {}, 0
    local function Bits(k)
        while bitcnt < k do
            bitbuf = bitbuf + s:byte(pos) * 2 ^ bitcnt
            pos = pos + 1
            bitcnt = bitcnt + 8
        end
        local v = bitbuf % 2 ^ k
        bitbuf = (bitbuf - v) / 2 ^ k
        bitcnt = bitcnt - k
        return math.floor(v)
    end
    local function Decode(map)
        local code, len = 0, 0
        while true do
            code = code * 2 + Bits(1)
            len = len + 1
            local sym = map[len * 65536 + code]
            if sym then return sym end
        end
    end
    local fixedLit, fixedDist
    repeat
        local final = Bits(1)
        local kind = Bits(2)
        if kind == 0 then
            bitbuf, bitcnt = 0, 0
            local len = s:byte(pos) + s:byte(pos + 1) * 256
            pos = pos + 4
            for k = 0, len - 1 do n = n + 1; out[n] = s:byte(pos + k) end
            pos = pos + len
        else
            local lit, dist
            if kind == 1 then
                if not fixedLit then
                    local l = {}
                    for k = 0, 143 do l[k] = 8 end
                    for k = 144, 255 do l[k] = 9 end
                    for k = 256, 279 do l[k] = 7 end
                    for k = 280, 287 do l[k] = 8 end
                    fixedLit = Codes(l, 288)
                    local d = {}
                    for k = 0, 29 do d[k] = 5 end
                    fixedDist = Codes(d, 30)
                end
                lit, dist = fixedLit, fixedDist
            else
                local hlit, hdist, hclen = Bits(5) + 257, Bits(5) + 1, Bits(4) + 4
                local cl = {}
                for k = 1, hclen do cl[CL_ORDER[k]] = Bits(3) end
                local clMap = Codes(cl, 19)
                local lens, k = {}, 0
                while k < hlit + hdist do
                    local sym = Decode(clMap)
                    if sym < 16 then
                        lens[k] = sym
                        k = k + 1
                    else
                        local val = sym == 16 and lens[k - 1] or 0
                        local rep = (sym == 16 and 3 + Bits(2)) or (sym == 17 and 3 + Bits(3)) or 11 + Bits(7)
                        for _ = 1, rep do lens[k] = val; k = k + 1 end
                    end
                end
                local ll, dl = {}, {}
                for i = 0, hlit - 1 do ll[i] = lens[i] end
                for i = 0, hdist - 1 do dl[i] = lens[hlit + i] end
                lit, dist = Codes(ll, hlit), Codes(dl, hdist)
            end
            while true do
                local sym = Decode(lit)
                if sym < 256 then
                    n = n + 1
                    out[n] = sym
                elseif sym == 256 then
                    break
                else
                    local i = sym - 256
                    local len = LEN_BASE[i] + Bits(LEN_EXTRA[i])
                    local d = Decode(dist) + 1
                    local back = DIST_BASE[d] + Bits(DIST_EXTRA[d])
                    for _ = 1, len do
                        n = n + 1
                        out[n] = out[n - back]
                    end
                end
            end
        end
    until final == 1
    local parts = {}
    for i = 1, n, 4096 do
        parts[#parts + 1] = string.char(unpack(out, i, math.min(n, i + 4095)))
    end
    return table.concat(parts)
end

return Inflate

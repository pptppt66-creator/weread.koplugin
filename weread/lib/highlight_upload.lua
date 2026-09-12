--[[--
KOReader 划线上传到微信读书 (可配置划线样式与极速缓存版)
]]

local logger = require("weread.lib.logger")
local PluginUtil = require("weread.lib.plugin_util")

local HighlightUpload = {}

-- 划线样式枚举常量
HighlightUpload.STYLE_LINE = 0    -- 直线/下划线
HighlightUpload.STYLE_MARKER = 1  -- 马克笔/高亮背景
HighlightUpload.STYLE_WAVE = 2    -- 波浪线

-- 默认划线样式设置（缺省设置为 2：波浪线）
HighlightUpload.DEFAULT_STYLE = HighlightUpload.STYLE_WAVE

HighlightUpload.MAX_SEARCH_CHAPTERS = 8
-- 单章 HTML 大小上限（字节）：超过 180KB 的超大章节直接跳过并释放内存，防止 OOM
HighlightUpload.MAX_CHAPTER_HTML_BYTES = 180 * 1024

-- 内存缓存：最多保留 3 章的 HTML 文本（同章连续划线 0ms 下载开销）
HighlightUpload.html_cache = HighlightUpload.html_cache or {}
HighlightUpload.cache_queue = HighlightUpload.cache_queue or {}

local function getCachedHtml(uid)
    return HighlightUpload.html_cache[tostring(uid)]
end

local function setCachedHtml(uid, html)
    local key = tostring(uid)
    if not HighlightUpload.html_cache[key] then
        table.insert(HighlightUpload.cache_queue, key)
        if #HighlightUpload.cache_queue > 3 then
            local old_key = table.remove(HighlightUpload.cache_queue, 1)
            HighlightUpload.html_cache[old_key] = nil
            collectgarbage("collect")
        end
    end
    HighlightUpload.html_cache[key] = html
end

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64_encode(data)
    data = tostring(data or "")
    if data == "" then return "" end
    local result = {}
    local len = #data
    local i = 1
    while i <= len do
        local b1 = data:byte(i) or 0
        local b2 = data:byte(i + 1) or 0
        local b3 = data:byte(i + 2) or 0
        local n = b1 * 65536 + b2 * 256 + b3
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        result[#result + 1] = b64chars:sub(c1 + 1, c1 + 1)
        result[#result + 1] = b64chars:sub(c2 + 1, c2 + 1)
        result[#result + 1] = (i + 1 <= len) and b64chars:sub(c3 + 1, c3 + 1) or "="
        result[#result + 1] = (i + 2 <= len) and b64chars:sub(c4 + 1, c4 + 1) or "="
        i = i + 3
    end
    return table.concat(result)
end

local function toRunes(str)
    local runes = {}
    local i, len = 1, #str
    while i <= len do
        local byte = string.byte(str, i)
        local rune_len = byte < 0x80 and 1 or (byte < 0xE0 and 2 or (byte < 0xF0 and 3 or 4))
        runes[#runes + 1] = str:sub(i, i + rune_len - 1)
        i = i + rune_len
    end
    return runes
end

local function stripHtmlToText(runes)
    local text_chars, byte_to_rune = {}, {}
    local inTag, byte_offset = false, 0
    for i, r in ipairs(runes) do
        if r == '<' then inTag = true
        elseif r == '>' then inTag = false
        elseif not inTag then
            text_chars[#text_chars + 1] = r
            for _b = 1, #r do
                byte_offset = byte_offset + 1
                byte_to_rune[byte_offset] = i - 1
            end
        end
    end
    return table.concat(text_chars), byte_to_rune
end

local function compact(s)
    if not s then return "" end
    return (s:gsub("%s+", ""):gsub("\227\128\128", ""):gsub("\194\160", ""))
end

local function cleanTitle(str)
    if not str then return "" end
    return tostring(str):lower():gsub("%s+", ""):gsub("[%p%c]", ""):gsub("\227\128\128", ""):gsub("\194\160", "")
end

local function findInText(haystack, needle)
    if not haystack or not needle or #needle == 0 then return nil end
    local s = haystack:find(needle, 1, true)
    if s then return s, s + #needle - 1 end

    local compact_hay = compact(haystack)
    local compact_needle = compact(needle)
    if #compact_needle == 0 then return nil end
    local cs = compact_hay:find(compact_needle, 1, true)
    if not cs then return nil end

    local nonspace_count, orig_start = 0, nil
    for i = 1, #haystack do
        if not haystack:sub(i, i):match("%s") then
            nonspace_count = nonspace_count + 1
            if nonspace_count == cs then orig_start = i; break end
        end
    end
    if not orig_start then return nil end

    nonspace_count = 0
    local orig_end = orig_start
    for i = orig_start, #haystack do
        if not haystack:sub(i, i):match("%s") then
            nonspace_count = nonspace_count + 1
            if nonspace_count >= #compact_needle then orig_end = i; break end
        end
    end
    return orig_start, orig_end
end

function HighlightUpload.findRangeInHtml(html, quote)
    if type(html) ~= "string" or html == "" or type(quote) ~= "string" or quote == "" then return nil end
    quote = quote:gsub("^%s+", ""):gsub("%s+$", "")
    if #quote == 0 then return nil end

    -- 极速剪枝：提取前 9 字节做预检
    local sample = quote:sub(1, 9)
    if #sample >= 3 and not html:find(sample, 1, true) then
        local compact_sample = compact(sample)
        if #compact_sample >= 3 and not html:find(compact_sample, 1, true) then
            return nil
        end
    end

    local runes = toRunes(html)
    local plain_text, byte_to_rune = stripHtmlToText(runes)
    runes = nil

    local start, end_pos = findInText(plain_text, quote)
    if not start or not end_pos then return nil end

    local rune_start = byte_to_rune[start]
    local rune_end = byte_to_rune[end_pos]
    plain_text, byte_to_rune = nil, nil

    if rune_start == nil or rune_end == nil then return nil end
    return string.format("%d-%d", rune_start, rune_end + 1)
end

local function getChapterHtml(plugin, book, chapter)
    local uid = chapter.chapterUid or chapter.chapterId or chapter.uid
    if uid then
        local cached = getCachedHtml(uid)
        if cached then return cached end
    end

    local Content = package.loaded["weread.lib.content"] or require("weread.lib.content")
    if Content and type(Content.fetch_chapter_xhtml) == "function" then
        local ok, html = pcall(Content.fetch_chapter_xhtml, plugin.client, plugin.settings, book, chapter)
        if ok and type(html) == "string" and #html > 0 then
            -- 大小防爆限制：超过限制直接拦截、弃用并强制垃圾回收，不写入缓存
            if #html > HighlightUpload.MAX_CHAPTER_HTML_BYTES then
                logger.warn("highlight_upload: chapter HTML exceeds size limit, skipped", 
                    "uid=", uid, "bytes=", #html, "limit=", HighlightUpload.MAX_CHAPTER_HTML_BYTES)
                html = nil
                collectgarbage("collect")
                return nil
            end

            if uid then setCachedHtml(uid, html) end
            return html
        end
    end
    return nil
end

local function getChapters(plugin, book_id, book)
    local books = plugin.settings:get("books", {})
    local b = books[tostring(book_id)] or books[book_id] or book
    if type(b) == "table" and type(b.chapters) == "table" and #b.chapters > 0 then
        return b.chapters
    end
    local Content = package.loaded["weread.lib.content"] or require("weread.lib.content")
    if Content and type(Content.fetch_catalog) == "function" then
        local ok, chapters = pcall(Content.fetch_catalog, plugin.client, b or { bookId = book_id })
        if ok and type(chapters) == "table" and #chapters > 0 then return chapters end
    end
    return nil
end

local function currentChapterIndex(plugin, chapters, book)
    if not chapters or #chapters == 0 then return nil end

    if plugin.ui and plugin.ui.document then
        local doc = plugin.ui.document
        local current_page = type(doc.getCurrentPage) == "function" and doc:getCurrentPage()
        local toc = type(doc.getToc) == "function" and doc:getToc()

        local current_toc_title = nil
        if current_page and toc and type(toc) == "table" then
            local function walk(nodes)
                for _, node in ipairs(nodes) do
                    if node.page and node.page <= current_page then
                        if node.title and node.title ~= "" then current_toc_title = node.title end
                        if node.nodes and #node.nodes > 0 then walk(node.nodes) end
                    else
                        break
                    end
                end
            end
            walk(toc)
        end

        if current_toc_title then
            local clean_toc = cleanTitle(current_toc_title)
            if clean_toc ~= "" then
                for i, ch in ipairs(chapters) do
                    if ch.title and cleanTitle(ch.title) == clean_toc then
                        return i
                    end
                end
                for i, ch in ipairs(chapters) do
                    if ch.title then
                        local clean_ch = cleanTitle(ch.title)
                        if #clean_ch >= 3 and #clean_toc >= 3 then
                            if clean_ch:find(clean_toc, 1, true) or clean_toc:find(clean_ch, 1, true) then
                                return i
                            end
                        end
                    end
                end
            end
        end
    end

    if type(book) == "table" then
        local uid = book.chapter_uid or book.chapterUid or book.chapterId
        if uid then
            for i, ch in ipairs(chapters) do
                local ch_uid = ch.chapterUid or ch.chapterId or ch.uid
                if tostring(ch_uid) == tostring(uid) then return i end
            end
        end
    end

    return 1
end

function HighlightUpload.sync(plugin, highlight)
    if not plugin or not highlight then return false, "invalid arguments" end

    local text = highlight.selected_text and highlight.selected_text.text
    if type(text) ~= "string" or text == "" then return false, "no highlight text" end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if #text == 0 or #text > 500 then return false, "invalid highlight length" end

    local book_id = nil
    if type(plugin.detectWeReadBook) == "function" then
        local ok, result = pcall(plugin.detectWeReadBook, plugin)
        if ok then book_id = type(result) == "table" and (result.book_id or result.bookId) or result end
    end
    if not book_id then return false, "当前书本未绑定微信读书" end
    book_id = tostring(book_id)

    local books = plugin.settings:get("books", {})
    local book = books[book_id] or books[tonumber(book_id)]
    local chapters = getChapters(plugin, book_id, book)
    if not chapters or #chapters == 0 then return false, "无法获取章节目录" end

    local current_idx = currentChapterIndex(plugin, chapters, book) or 1
    
    local search_order = {}
    local added = {}
    local function addChapter(idx)
        if idx >= 1 and idx <= #chapters and not added[idx] and #search_order < HighlightUpload.MAX_SEARCH_CHAPTERS then
            added[idx] = true
            search_order[#search_order + 1] = idx
        end
    end

    addChapter(current_idx)
    for f = 1, 5 do addChapter(current_idx + f) end
    for b = 1, 2 do addChapter(current_idx - b) end

    local chapter_uid, range, chapter_obj = nil, nil, nil
    for _, idx in ipairs(search_order) do
        local chapter = chapters[idx]
        local uid = chapter.chapterUid or chapter.chapterId or chapter.uid
        if uid then
            local html = getChapterHtml(plugin, book or { bookId = book_id }, chapter)
            if html then
                local found = HighlightUpload.findRangeInHtml(html, text)
                if found then
                    chapter_uid = uid
                    range = found
                    chapter_obj = chapter
                    break
                end
            end
        end
    end

    if not chapter_uid or not range then
        return false, "在微信读书版本中未找到对应文本（可能版本/排版不同或章节过大跳过）"
    end

    local book_version = (type(book) == "table" and (book.bookVersion or book.book_version or book.version)) or 0
    local ch_idx = (type(chapter_obj) == "table" and (chapter_obj.chapterIdx or chapter_obj.idx)) or 0

    local payload = {
        bookId = tostring(book_id),
        chapterUid = tonumber(chapter_uid) or chapter_uid,
        chapterIdx = tonumber(ch_idx) or 0,
        bookVersion = tonumber(book_version) or 0,
        type = 1,
        style = HighlightUpload.DEFAULT_STYLE or HighlightUpload.STYLE_WAVE,
        colorStyle = 0,
        range = range,
        markText = base64_encode(text),
    }

    local pcall_ok, sync_ok, sync_err = pcall(function()
        return plugin.client:add_bookmark(payload)
    end)

    if not pcall_ok then return false, "API 调用异常：" .. tostring(sync_ok) end
    if not sync_ok then return false, sync_err or "同步失败" end

    return true
end

return HighlightUpload

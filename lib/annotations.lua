--[[--
微信读书划线标注处理

将微信读书的划线数据注入到章节 HTML 中。
划线 range 格式：如 "383-415"，表示 HTML 字符串的 rune 索引（包含所有标签）。
--]] --

local logger = require("logger")

local Annotations = {}

-- 下划线 CSS 样式
Annotations.UNDERLINE_CSS = [[
.wr-underline {
    border-bottom: 2px dashed #ff6b35;
    padding-bottom: 2px;
}
]]

-- 想法标记（星号）CSS 样式 — 浅色、右上角、小字号
Annotations.THOUGHT_CSS = [[
.wr-thought-link{text-decoration:none;color:inherit;}
.wr-thought-link .wr-underline{color:inherit;}
.wr-star{font-size:0.6em;vertical-align:super;line-height:0;color:#aaa;margin-left:1px;}
]]

--- 去除字符串开头的 UTF-8 BOM（\ufeff）。
-- WeRead 的部分章节会携带 BOM，而下划线 range 索引通常不包含这个字符。
local function stripLeadingBOM(s)
    if type(s) ~= "string" then return s end
    -- UTF-8 BOM: EF BB BF
    if s:sub(1, 3) == "\xef\xbb\xbf" then
        return s:sub(4)
    end
    return s
end

--- 将 UTF-8 字符串转换为 rune 数组。
local function toRunes(str)
    local runes = {}
    local i = 1
    local len = #str
    while i <= len do
        local byte = string.byte(str, i)
        local rune_len
        if byte < 0x80 then
            rune_len = 1
        elseif byte < 0xE0 then
            rune_len = 2
        elseif byte < 0xF0 then
            rune_len = 3
        else
            rune_len = 4
        end
        runes[#runes + 1] = str:sub(i, i + rune_len - 1)
        i = i + rune_len
    end
    return runes
end

--- 按 rune 数量截断字符串，避免 UTF-8 多字节字符被切半。
local function truncateRunes(str, max_runes)
    if type(str) ~= "string" or max_runes <= 0 then return "" end
    local runes = toRunes(str)
    if #runes <= max_runes then
        return str
    end
    local parts = {}
    for i = 1, max_runes do
        parts[#parts + 1] = runes[i]
    end
    return table.concat(parts) .. "…"
end

--- 解析 range 字符串（如 "383-415"）为起止位置。
-- 注意：微信读书 API 返回的 range 是 0 索引（JavaScript 惯例），
-- 但 Lua 使用 1 索引。需要加 1 转换。
local function parseRange(range_str)
    if type(range_str) ~= "string" or range_str == "" then
        return nil, nil
    end
    local start_str, end_str = range_str:match("^(%d+)%-(%d+)$")
    if not start_str or not end_str then
        return nil, nil
    end
    -- 加 1 转换为 Lua 1 索引
    local start = tonumber(start_str) + 1
    local end_pos = tonumber(end_str) + 1
    if not start or not end_pos or start >= end_pos then
        return nil, nil
    end
    return start, end_pos
end

--- snapEndToSafeBoundary 将 end 位置向前（回退）调整，使其不落在 HTML 标签或实体内部。
local function snapEndToSafeBoundary(runes, start, end_pos)
    local n = #runes
    if end_pos <= start or end_pos > n + 1 then
        return end_pos
    end
    -- 检查是否在 HTML 标签内部：从 end-1 向前扫描
    for i = end_pos - 1, start, -1 do
        if runes[i] == '>' then
            break -- 遇到 >，说明不在标签内部
        end
        if runes[i] == '<' then
            return i -- 在标签内部，回退到 < 之前
        end
    end
    -- 检查是否在 HTML 实体内部：从 end-1 向前扫描（实体最长约 10 字符）
    for i = end_pos - 1, start, -1 do
        if i < end_pos - 12 then break end
        local r = runes[i]
        if r == ';' or r == '<' or r == '>' then
            break -- 遇到分隔符，说明不在实体内部
        end
        if r == '&' then
            return i -- 在实体内部，回退到 & 之前
        end
    end
    return end_pos
end

--- snapStartToSafeBoundary 将 start 位置向后（前进）调整，使其不落在 HTML 标签或实体内部。
local function snapStartToSafeBoundary(runes, start, end_pos)
    local n = #runes
    if start < 1 or start >= end_pos or start > n then
        return start
    end
    -- 检查是否在 HTML 标签内部：从 start-1 向前扫描
    for i = start - 1, 1, -1 do
        if i < start - 200 then break end
        if runes[i] == '>' then
            break -- 不在标签内部
        end
        if runes[i] == '<' then
            -- 在标签内部，向前找到闭合 >
            for j = start, n do
                if runes[j] == '>' then
                    return j + 1
                end
            end
            break
        end
    end
    -- 检查是否在 HTML 实体内部：从 start-1 向前扫描
    for i = start - 1, 1, -1 do
        if i < start - 12 then break end
        local r = runes[i]
        if r == ';' or r == '<' or r == '>' then
            break
        end
        if r == '&' then
            -- 在实体内部，向前找到闭合 ;
            for j = start, n do
                if j >= start + 12 then break end
                if runes[j] == ';' then
                    return j + 1
                end
            end
            break
        end
    end
    return start
end

--- wrapTextSegments 将 rune 切片中的每个文本段（非标签部分）分别用 <span> 包裹。
-- 遇到 HTML 标签时自动关闭/重开 span，确保不跨越标签边界。
local function wrapTextSegments(runes, className)
    local openTag = '<span class="' .. className .. '">'
    local closeTag = '</span>'

    local result = {}
    local inTag = false
    local textBuf = {}

    -- 包裹一个文本段
    local function wrapSegment(seg)
        if #seg == 0 then return end
        -- 检查是否纯空白
        local hasContent = false
        for _, r in ipairs(seg) do
            if not r:match("^%s$") then
                hasContent = true
                break
            end
        end
        if hasContent then
            result[#result + 1] = openTag
            for _, r in ipairs(seg) do
                result[#result + 1] = r
            end
            result[#result + 1] = closeTag
        else
            for _, r in ipairs(seg) do
                result[#result + 1] = r
            end
        end
    end

    -- 刷新文本缓冲区
    local function flushTextBuf()
        if #textBuf == 0 then return end
        wrapSegment(textBuf)
        textBuf = {}
    end

    for _, r in ipairs(runes) do
        if r == '<' then
            flushTextBuf()
            inTag = true
            result[#result + 1] = r
        elseif r == '>' then
            inTag = false
            result[#result + 1] = r
        elseif inTag then
            result[#result + 1] = r
        else
            -- 文本字符：缓冲到 textBuf
            textBuf[#textBuf + 1] = r
        end
    end
    flushTextBuf()

    return result
end

--- HTML 转义
local function htmlEscape(text)
    text = tostring(text or "")
    text = text:gsub("&", "&amp;")
    text = text:gsub("<", "&lt;")
    text = text:gsub(">", "&gt;")
    text = text:gsub('"', "&quot;")
    return text
end

--- 内部锚点 ID。不要使用自定义外部协议，避免 KOReader 弹出“无效或外部链接”。
local function idSafe(text)
    text = tostring(text or "")
    text = text:gsub("[^%w%._%-]", "_")
    if text == "" then text = "unknown" end
    return text
end

local function thoughtAnchorId(book_id, chapter_uid, range_str)
    return "wrthought-" .. idSafe(book_id) .. "-" .. idSafe(chapter_uid) .. "-" .. idSafe(range_str)
end

local function thoughtHref(book_id, chapter_uid, range_str)
    -- 同文件内部锚点。插件拦截成功时显示自定义弹窗；若拦截失败，也只会跳到当前划线处，不会打开外部链接。
    return "#" .. thoughtAnchorId(book_id, chapter_uid, range_str)
end


-- 评论位置允许使用修正后的 range，但锚点和缓存查询必须继续使用微信读书返回的原始 range。
local function anchorRangeString(underline)
    return tostring(underline.originalRange or underline.range or "")
end

local HTML_ENTITIES = {
    amp = "&",
    apos = "'",
    gt = ">",
    lt = "<",
    nbsp = " ",
    quot = '"',
    ensp = " ",
    emsp = " ",
    thinsp = " ",
}

local BLOCK_TAGS = {
    address = true, article = true, aside = true, blockquote = true,
    br = true, caption = true, dd = true, div = true, dl = true, dt = true,
    figcaption = true, figure = true, footer = true, h1 = true, h2 = true,
    h3 = true, h4 = true, h5 = true, h6 = true, header = true, hr = true,
    li = true, main = true, nav = true, ol = true, p = true, pre = true,
    section = true, table = true, tbody = true, td = true, tfoot = true,
    th = true, thead = true, tr = true, ul = true,
}

local SURROUNDING_QUOTES = {
    ['"'] = '"', ["'"] = "'",
    ["“"] = "”", ["‘"] = "’",
    ["「"] = "」", ["『"] = "』",
    ["《"] = "》", ["〈"] = "〉",
}

local function codepointToUtf8(cp)
    cp = tonumber(cp)
    if not cp or cp < 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
        return nil
    end
    if cp <= 0x7F then
        return string.char(cp)
    elseif cp <= 0x7FF then
        return string.char(
            0xC0 + math.floor(cp / 0x40),
            0x80 + (cp % 0x40)
        )
    elseif cp <= 0xFFFF then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + (math.floor(cp / 0x40) % 0x40),
            0x80 + (cp % 0x40)
        )
    end
    return string.char(
        0xF0 + math.floor(cp / 0x40000),
        0x80 + (math.floor(cp / 0x1000) % 0x40),
        0x80 + (math.floor(cp / 0x40) % 0x40),
        0x80 + (cp % 0x40)
    )
end

local function decodeHtmlEntity(entity)
    if type(entity) ~= "string" or #entity < 3 then
        return nil
    end
    local body = entity:match("^&([^;]+);$")
    if not body then
        return nil
    end
    local named = HTML_ENTITIES[body:lower()]
    if named then
        return named
    end
    local hex = body:match("^#[xX]([0-9a-fA-F]+)$")
    if hex then
        return codepointToUtf8(tonumber(hex, 16))
    end
    local dec = body:match("^#(%d+)$")
    if dec then
        return codepointToUtf8(tonumber(dec, 10))
    end
    return nil
end

local function isIgnoredRune(r)
    return r == "\226\128\139" -- U+200B ZERO WIDTH SPACE
        or r == "\226\128\140" -- U+200C ZERO WIDTH NON-JOINER
        or r == "\226\128\141" -- U+200D ZERO WIDTH JOINER
        or r == "\226\129\160" -- U+2060 WORD JOINER
        or r == "\239\187\191" -- U+FEFF BOM / zero-width no-break space
end

local function normalizeRune(r)
    if isIgnoredRune(r) then
        return nil
    end
    if r == "　" or r:match("^%s$") then
        return " "
    end
    return r
end

local function appendNormalizedRune(text_runes, html_starts, html_ends, rune, html_start, html_end)
    rune = normalizeRune(rune)
    if not rune then
        return
    end
    if rune == " " and text_runes[#text_runes] == " " then
        -- 折叠连续空白，但扩展 HTML 结束位置，保证最终 range 不落在空白序列内部。
        html_ends[#html_ends] = math.max(html_ends[#html_ends] or html_end, html_end)
        return
    end
    text_runes[#text_runes + 1] = rune
    html_starts[#html_starts + 1] = html_start
    html_ends[#html_ends + 1] = html_end
end

local function trimRuneArrays(runes, starts, ends)
    while #runes > 0 and runes[1] == " " do
        table.remove(runes, 1)
        if starts then table.remove(starts, 1) end
        if ends then table.remove(ends, 1) end
    end
    while #runes > 0 and runes[#runes] == " " do
        table.remove(runes)
        if starts then table.remove(starts) end
        if ends then table.remove(ends) end
    end
end

-- 将章节 HTML 转为规范化可见文本，并记录每个文本 rune 对应的 HTML 0-based 起止坐标。
-- 行级标签被折叠为空格；script/style 内容被忽略；常见实体会解码后参与匹配。
local function buildTextMapping(html)
    local html_runes = toRunes(html)
    local text_runes, html_starts, html_ends = {}, {}, {}
    local n = #html_runes
    local i = 1
    local skip_content_tag = nil

    while i <= n do
        local r = html_runes[i]
        if r == "<" then
            local close_pos = nil
            for j = i + 1, n do
                if html_runes[j] == ">" then
                    close_pos = j
                    break
                end
            end
            if not close_pos then
                appendNormalizedRune(text_runes, html_starts, html_ends, r, i - 1, i)
                i = i + 1
            else
                local tag_parts = {}
                for j = i + 1, close_pos - 1 do
                    tag_parts[#tag_parts + 1] = html_runes[j]
                end
                local tag_text = table.concat(tag_parts)
                local closing, tag_name = tag_text:match("^%s*(/?)%s*([%w]+)")
                tag_name = tag_name and tag_name:lower() or nil

                if skip_content_tag then
                    if closing == "/" and tag_name == skip_content_tag then
                        skip_content_tag = nil
                    end
                elseif tag_name == "script" or tag_name == "style" then
                    if closing ~= "/" then
                        skip_content_tag = tag_name
                    end
                elseif tag_name and BLOCK_TAGS[tag_name] then
                    appendNormalizedRune(text_runes, html_starts, html_ends, " ", i - 1, close_pos)
                end
                i = close_pos + 1
            end
        elseif skip_content_tag then
            i = i + 1
        elseif r == "&" then
            local entity_end = nil
            for j = i + 1, math.min(i + 16, n) do
                if html_runes[j] == ";" then
                    entity_end = j
                    break
                elseif html_runes[j] == "<" or html_runes[j] == ">" or html_runes[j] == " " then
                    break
                end
            end
            if entity_end then
                local entity_parts = {}
                for j = i, entity_end do
                    entity_parts[#entity_parts + 1] = html_runes[j]
                end
                local decoded = decodeHtmlEntity(table.concat(entity_parts))
                if decoded then
                    for _, decoded_rune in ipairs(toRunes(decoded)) do
                        appendNormalizedRune(text_runes, html_starts, html_ends, decoded_rune, i - 1, entity_end)
                    end
                    i = entity_end + 1
                else
                    appendNormalizedRune(text_runes, html_starts, html_ends, r, i - 1, i)
                    i = i + 1
                end
            else
                appendNormalizedRune(text_runes, html_starts, html_ends, r, i - 1, i)
                i = i + 1
            end
        else
            appendNormalizedRune(text_runes, html_starts, html_ends, r, i - 1, i)
            i = i + 1
        end
    end

    trimRuneArrays(text_runes, html_starts, html_ends)
    return text_runes, html_starts, html_ends
end

local function normalizeSearchRunes(text)
    if type(text) ~= "string" or text == "" then
        return {}
    end
    text = stripLeadingBOM(text)
    local input = toRunes(text)
    local runes = {}
    local dummy_starts, dummy_ends = {}, {}
    local i = 1
    while i <= #input do
        local r = input[i]
        if r == "&" then
            local entity_end = nil
            for j = i + 1, math.min(i + 16, #input) do
                if input[j] == ";" then
                    entity_end = j
                    break
                elseif input[j] == " " then
                    break
                end
            end
            if entity_end then
                local parts = {}
                for j = i, entity_end do parts[#parts + 1] = input[j] end
                local decoded = decodeHtmlEntity(table.concat(parts))
                if decoded then
                    for _, decoded_rune in ipairs(toRunes(decoded)) do
                        appendNormalizedRune(runes, dummy_starts, dummy_ends, decoded_rune, 0, 0)
                    end
                    i = entity_end + 1
                else
                    appendNormalizedRune(runes, dummy_starts, dummy_ends, r, 0, 0)
                    i = i + 1
                end
            else
                appendNormalizedRune(runes, dummy_starts, dummy_ends, r, 0, 0)
                i = i + 1
            end
        else
            appendNormalizedRune(runes, dummy_starts, dummy_ends, r, 0, 0)
            i = i + 1
        end
    end
    trimRuneArrays(runes)

    -- 微信读书的 abstract 有时带成对引号，而章节正文没有。
    while #runes >= 2 and SURROUNDING_QUOTES[runes[1]] == runes[#runes] do
        table.remove(runes, 1)
        table.remove(runes)
        trimRuneArrays(runes)
    end
    return runes
end

local function runesMatchAt(text_runes, needle, pos)
    if pos < 1 or pos + #needle - 1 > #text_runes then
        return false
    end
    for j = 1, #needle do
        if text_runes[pos + j - 1] ~= needle[j] then
            return false
        end
    end
    return true
end

local function nearestTextIndex(html_starts, html_pos)
    local count = #html_starts
    if count == 0 then return 1 end
    local lo, hi = 1, count
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if (html_starts[mid] or 0) < html_pos then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    if lo > count then return count end
    if lo <= 1 then return 1 end
    local before = html_starts[lo - 1] or 0
    local after = html_starts[lo] or 0
    if math.abs(before - html_pos) <= math.abs(after - html_pos) then
        return lo - 1
    end
    return lo
end

local function findBestMatch(text_runes, html_starts, needle, old_start, first_pos, last_pos)
    if #needle == 0 or #needle > #text_runes then
        return nil
    end
    first_pos = math.max(1, first_pos or 1)
    last_pos = math.min(#text_runes - #needle + 1, last_pos or (#text_runes - #needle + 1))
    if first_pos > last_pos then
        return nil
    end

    local best, best_dist = nil, math.huge
    local first_rune = needle[1]
    for i = first_pos, last_pos do
        if text_runes[i] == first_rune and runesMatchAt(text_runes, needle, i) then
            local distance = math.abs((html_starts[i] or 0) - old_start)
            if distance < best_dist then
                best, best_dist = i, distance
                if distance == 0 then break end
            end
        end
    end
    return best
end

local function fixUnderlineRange(text_runes, html_starts, html_ends, underline)
    local abstract_runes = normalizeSearchRunes(underline.abstract)
    if #abstract_runes < 2 or #abstract_runes > #text_runes then
        return nil
    end

    local original_range = anchorRangeString(underline)
    local old_start = tonumber(original_range:match("^(%d+)")) or 0
    local center = nearestTextIndex(html_starts, old_start)
    local window = math.max(1200, #abstract_runes * 6)

    -- 优先在原始 range 附近搜索，减少重复短句被匹配到远处的风险。
    local best = findBestMatch(
        text_runes, html_starts, abstract_runes, old_start,
        center - window, center + window
    )
    if not best then
        best = findBestMatch(text_runes, html_starts, abstract_runes, old_start)
    end
    if not best then
        return nil
    end

    local html_start = html_starts[best]
    local html_end = html_ends[best + #abstract_runes - 1]
    if html_start == nil or html_end == nil or html_end <= html_start then
        return nil
    end

    local new_range = tostring(html_start) .. "-" .. tostring(html_end)
    if new_range ~= tostring(underline.range or "") then
        logger.info(
            "[WeRead] annotation range corrected:",
            "old=", tostring(underline.range),
            "new=", new_range,
            "abstract=", truncateRunes(underline.abstract, 40)
        )
    end
    return new_range
end

local function firstReviewAbstract(range_review)
    if type(range_review) ~= "table" or type(range_review.pageReviews) ~= "table" then
        return nil
    end
    for _, page_review in ipairs(range_review.pageReviews) do
        local review = type(page_review) == "table" and page_review.review or nil
        if type(review) == "table" then
            local abstract = review.abstract or review.contextAbstract
            if type(abstract) == "string" and abstract:match("%S") then
                return abstract
            end
        end
    end
    return nil
end

--- 微信读书想法/评论不再写入 EPUB 正文。
-- 评论内容保存在 thoughts/*.json，由 main.lua 拦截内部锚点并显示自定义弹窗。
-- 这里的链接只使用 #wrthought-... 内部锚点，不使用 wrthought://，也不生成 footnote aside。

--- 在 HTML 中注入下划线标记。
-- @string html  完整的原始 HTML（包含 body 标签）
-- @table  underlines  划线列表
-- @table  thought_reviews  想法数据 map
-- @return processed_html
function Annotations.injectUnderlines(html, underlines, thought_reviews, book_id, chapter_uid)
    if type(html) ~= "string" or html == "" then
        return html
    end
    if type(underlines) ~= "table" or #underlines == 0 then
        return html
    end

    -- 去除 BOM，避免下划线位置偏移
    local original_html = html
    html = stripLeadingBOM(html)
    if html ~= original_html then
        logger.info("weread annotations: stripped BOM")
    end

    -- 解析所有 range。显示位置可使用修正后的 range，评论绑定仍使用 originalRange。
    local ranges = {}
    for _, underline in ipairs(underlines) do
        local range_str = underline.range
        if range_str then
            local start_pos, end_pos = parseRange(range_str)
            if start_pos and end_pos and start_pos < end_pos and start_pos >= 1 then
                ranges[#ranges + 1] = {
                    range_str = range_str,
                    start = start_pos,
                    end_pos = end_pos,
                    hasThought = underline.hasThought == true,
                    originalRange = underline.originalRange,
                }
            end
        end
    end

    if #ranges == 0 then
        return html
    end

    -- 按起始位置排序
    table.sort(ranges, function(a, b) return a.start < b.start end)

    -- 转换为 rune 数组
    local runes = toRunes(html)
    local n = #runes

    logger.info("weread annotations: html runes=", n, "underlines=", #ranges)

    -- 预计算所有替换片段
    local replacements = {}
    local prevEnd = 1

    for _, ul in ipairs(ranges) do
        local start_pos = ul.start
        local end_pos = ul.end_pos

        -- 边界检查（range 结束坐标允许为 n + 1，表示包含章节最后一个 rune）
        if start_pos < 1 or end_pos > n + 1 or start_pos >= end_pos then
            goto continue
        end

        -- 校正边界：确保 start 和 end 不落在 HTML 标签或实体内部
        end_pos = snapEndToSafeBoundary(runes, start_pos, end_pos)
        start_pos = snapStartToSafeBoundary(runes, start_pos, end_pos)

        -- 确保不重叠
        if start_pos >= end_pos or start_pos < prevEnd then
            goto continue
        end

        -- 提取范围内的内容并包裹下划线标签
        local inner = {}
        for j = start_pos, end_pos - 1 do
            inner[#inner + 1] = runes[j]
        end

        -- 使用 wrapTextSegments 处理跨标签边界
        local wrapped = wrapTextSegments(inner, "wr-underline")

        -- 如果有想法数据：被下划线选中的“正文内容”成为可点击锚点；星号只作为视觉标记，不可点击。
        -- 不使用 wrthought://，避免 KOReader 外部链接提示；不生成 footnote aside，避免评论进入正文分页。
        if ul.hasThought then
            local underline_open = '<span class="wr-underline">'
            local underline_close = '</span>'
            local underline_close_with_star = '</span><span class="wr-star">*</span>'

            -- 星号放在最后一个 underline span 之后，并且放在 </a> 之外。
            local last_idx = #wrapped
            if wrapped[last_idx] == underline_close then
                wrapped[last_idx] = underline_close_with_star
            end

            local data_range = anchorRangeString(ul)
            local anchor_id = thoughtAnchorId(book_id, chapter_uid, data_range)
            local href = "#" .. anchor_id
            local data_wr_attr = ' data-wr-range="' .. htmlEscape(data_range) .. '"'
            local open_a = '<a class="wr-thought-link"' .. data_wr_attr
                .. ' data-wr-book="' .. htmlEscape(book_id or '')
                .. '" data-wr-chapter="' .. htmlEscape(chapter_uid or '')
                .. '" href="' .. htmlEscape(href) .. '">'
            local open_a_with_id = '<a id="' .. htmlEscape(anchor_id) .. '" class="wr-thought-link"' .. data_wr_attr
                .. ' data-wr-book="' .. htmlEscape(book_id or '')
                .. '" data-wr-chapter="' .. htmlEscape(chapter_uid or '')
                .. '" href="' .. htmlEscape(href) .. '">'

            -- wrapTextSegments 为每个文本段生成独立的 underline span；逐 span 包裹 <a>。
            -- 只有第一个 <a> 带 id，默认跳转时只会回到划线起点；正常情况下由 main.lua 拦截并弹窗。
            local with_links = {}
            local first_link = true
            for _, item in ipairs(wrapped) do
                if item == underline_open then
                    with_links[#with_links + 1] = first_link and open_a_with_id or open_a
                    first_link = false
                    with_links[#with_links + 1] = item
                elseif item == underline_close then
                    with_links[#with_links + 1] = item
                    with_links[#with_links + 1] = '</a>'
                elseif item == underline_close_with_star then
                    with_links[#with_links + 1] = '</span>'
                    with_links[#with_links + 1] = '</a>'
                    with_links[#with_links + 1] = '<span class="wr-star">*</span>'
                else
                    with_links[#with_links + 1] = item
                end
            end
            wrapped = with_links
        end

        replacements[#replacements + 1] = {
            start = start_pos,
            end_pos = end_pos,
            content = wrapped,
        }
        prevEnd = end_pos

        ::continue::
    end

    if #replacements == 0 then
        return html
    end

    -- 单遍拼接：依次输出未修改段和替换片段
    local result = {}
    local prev = 1

    for _, rep in ipairs(replacements) do
        -- 输出未修改段
        for j = prev, rep.start - 1 do
            result[#result + 1] = runes[j]
        end
        -- 输出替换片段
        for _, r in ipairs(rep.content) do
            result[#result + 1] = r
        end
        prev = rep.end_pos
    end

    -- 输出剩余部分
    for j = prev, n do
        result[#result + 1] = runes[j]
    end

    return table.concat(result)
end

--- 处理章节数据中的划线标注。
-- @string html  原始 HTML 内容
-- @table  chapter_underlines  章节划线数据（来自 API）
-- @table  thought_reviews  想法数据 map（可选），keyed by range string
-- @return processed_html, css  处理后的 HTML 和额外的 CSS
function Annotations.process(html, chapter_underlines, thought_reviews, book_id)
    if type(html) ~= "string" or html == "" then
        return html, ""
    end

    if type(chapter_underlines) ~= "table" then
        return html, ""
    end

    local underlines = chapter_underlines.underlines
    if type(underlines) ~= "table" or #underlines == 0 then
        return html, ""
    end

    -- 先按原始 range 建立评论信息，再在副本中修正显示位置，避免污染 API 原始数据。
    local thought_by_range = {}
    if type(thought_reviews) == "table" then
        for _, range_review in ipairs(thought_reviews) do
            if range_review.range and type(range_review.pageReviews) == "table" and #range_review.pageReviews > 0 then
                thought_by_range[tostring(range_review.range)] = {
                    hasThought = true,
                    abstract = firstReviewAbstract(range_review),
                }
            end
        end
    end

    local prepared_underlines = {}
    for _, underline in ipairs(underlines) do
        if type(underline) == "table" and underline.range then
            local original_range = tostring(underline.range)
            local thought = thought_by_range[original_range]
            prepared_underlines[#prepared_underlines + 1] = {
                range = original_range,
                originalRange = original_range,
                hasThought = thought and thought.hasThought or false,
                abstract = thought and thought.abstract or nil,
            }
        end
    end

    local has_thoughts = next(thought_by_range) ~= nil
    logger.info(
        "weread annotations: processing", #prepared_underlines, "underlines",
        has_thoughts and "with thoughts" or ""
    )

    if has_thoughts then
        local text_runes, html_starts, html_ends = buildTextMapping(stripLeadingBOM(html))
        for _, underline in ipairs(prepared_underlines) do
            if underline.hasThought and underline.abstract then
                local corrected = fixUnderlineRange(text_runes, html_starts, html_ends, underline)
                if corrected then
                    underline.range = corrected
                end
            end
        end
    end

    local processed = Annotations.injectUnderlines(
        html, prepared_underlines, has_thoughts and thought_by_range or nil,
        book_id, chapter_underlines.chapterUid
    )

    -- 不再把微信读书想法/评论写入章节 body。
    -- 评论内容已由 thoughts.lua 缓存为 JSON；正文只保留划线锚点和视觉星号。
    -- 点击被下划线选中的正文时由 main.lua 拦截内部 #wrthought-... 链接并弹出自定义窗口。
    -- 不把评论写入 EPUB，因此不会进入主阅读流和页码。

    if processed ~= html then
        local css = Annotations.UNDERLINE_CSS
        if has_thoughts then
            css = css .. "\n" .. Annotations.THOUGHT_CSS
        end
        return processed, css
    end

    return html, ""
end

return Annotations

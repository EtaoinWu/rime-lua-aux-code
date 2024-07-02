local AuxFilter = {}

-- local log = require 'log'
-- log.outfile = "aux_code.log"

function AuxFilter.init(env)
    -- log.info("** AuxCode filter", env.name_space)

    AuxFilter.aux_code = AuxFilter.aux_code or AuxFilter.readAuxTxt(env.name_space)

    local engine = env.engine
    local config = engine.schema.config

    -- 設定預設觸發鍵為分號，並從配置中讀取自訂的觸發鍵
    env.trigger_key = config:get_string("aux_code/trigger_key") or ";"

    -- 设定是否显示辅助码
    -- always: 总是显示 (默认)
    -- never: 从不显示
    -- on_trigger: 仅在输入辅助码时显示
    env.show_auxcode_hint = config:get_string("aux_code/show_auxcode_hint") or "always"

    -- 設定避免輔助碼的正則表達式
    env.ignore_regex = config:get_string("aux_code/ignore_regex") or ""

    -- 設定是否顯示非匹配的候選詞
    -- filter: 仅显示匹配辅助码的候选项（默认）
    -- prioritize: 非匹配候选项放在最后
    -- option: 根据 switch 中的 aux_code_nonmatch_policy 选项决定
    env.nonmatch_policy = config:get_string("aux_code/nonmatch_policy") or "filter"

    -- 设定辅助码过滤模式
    -- single: 单字
    -- phrase: 全词
    -- option: 根据 switch 中的 aux_code_single_char 选项决定
    env.filter_mode = config:get_string("aux_code/filter_mode") or "phrase"

    ----------------------------
    -- 持續選詞上屏，保持輔助碼分隔符存在 --
    ----------------------------
    env.notifier = engine.context.select_notifier:connect(function(ctx)
        -- 含有輔助碼分隔符才處理
        if not string.find(ctx.input, env.trigger_key) then
            return
        end

        local preedit = ctx:get_preedit()
        local removeAuxInput = ctx.input:match("([^,]+)" .. env.trigger_key)
        local reeditTextFront = preedit.text:match("([^,]+)" .. env.trigger_key)

        -- ctx.text 隨著選字的進行，oaoaoa； 有如下的輸出：
        -- ---- 有輔助碼 ----
        -- >>> 啊 oaoa；au
        -- >>> 啊吖 oa；au
        -- >>> 啊吖啊；au
        -- ---- 無輔助碼 ----
        -- >>> 啊 oaoa；
        -- >>> 啊吖 oa；
        -- >>> 啊吖啊；
        -- 這邊把已經上屏的字段 (preedit:text) 進行分割；
        -- 如果已經全部選完了，分割後的結果就是 nil，否則都是 吖卡 a 這種字符串
        -- 驗證方式：
        -- log.info('select_notifier', ctx.input, removeAuxInput, preedit.text, reeditTextFront)

        -- 當最終不含有任何字母時 (候選)，就跳出分割模式，並把輔助碼分隔符刪掉
        ctx.input = removeAuxInput
        if reeditTextFront and reeditTextFront:match("[a-z]") then
            -- 給詞尾自動添加分隔符，上面的 re.match 會把分隔符刪掉
            ctx.input = ctx.input .. env.trigger_key
        else
            -- 剩下的直接上屏
            ctx:commit()
        end
    end)
end

----------------
-- 閱讀輔碼文件 --
----------------
function AuxFilter.readAuxTxt(txtpath)
    -- log.info("** AuxCode filter", 'read Aux code txt:', txtpath)

    local defaultFile = 'ZRM_Aux-code_4.3.txt'
    local userPath = rime_api.get_user_data_dir() .. "/lua/"
    local fileAbsolutePath = userPath .. txtpath .. ".txt"

    local file = io.open(fileAbsolutePath, "r") or io.open(userPath .. defaultFile, "r")
    if not file then
        error("Unable to open auxiliary code file.")
        return {}
    end

    local auxCodes = {}
    for line in file:lines() do
        line = line:match("[^\r\n]+") -- 去掉換行符，不然 value 是帶著 \n 的
        local key, value = line:match("([^=]+)=(.+)") -- 分割 = 左右的變數
        if key and value then
            auxCodes[key] = auxCodes[key] or {}
            table.insert(auxCodes[key], value)
        end
    end
    file:close()
    -- 確認 code 能打印出來
    -- for key, value in pairs(AuxFilter.aux_code) do
    --     log.info(key, table.concat(value, ','))
    -- end

    return auxCodes
end

-- local function getUtf8CharLength(byte)
--     if byte < 128 then
--         return 1
--     elseif byte < 224 then
--         return 2
--     elseif byte < 240 then
--         return 3
--     else
--         return 4
--     end
-- end

-- 輔助函數，用於獲取表格的所有鍵
local function table_keys(t)
    local keys = {}
    for key, _ in pairs(t) do
        table.insert(keys, key)
    end
    return keys
end

-----------------------------------------------
-- 計算詞語整體的輔助碼
-- 目前定義為
--   把字或词组的所有辅码，第一个键堆到一起，第二个键堆到一起
--   例子：
--       候选(word) = 拜日
--          【拜】 的辅码有 charAuxCodes=
--             p a
--             p u
--             u a
--             u f
--             u u
--          【日】 的辅码有 charAuxCodes=
--             o r
--             r i
--             a a
--             u h
--       (竖着拍成左右两个字符串)
--   第一个辅码键的不重复列表为：fullAuxCodes[1]= urpao 
--   第二个辅码键的不重复列表为：fullAuxCodes[2]= urhafi
-- -----------------------------------------------
function AuxFilter.fullAux(env, word, single_char_mode)
    local fullAuxCodes = {}
    -- log.info('候选词：', word)
    for _, codePoint in utf8.codes(word) do
        local char = utf8.char(codePoint)
        local charAuxCodes = AuxFilter.aux_code[char] -- 每個字的輔助碼組
        if charAuxCodes then -- 輔助碼存在
            for _, code in ipairs(charAuxCodes) do
                for i = 1, #code do
                    fullAuxCodes[i] = fullAuxCodes[i] or {}
                    fullAuxCodes[i][code:sub(i, i)] = true
                end
            end
        end
        if single_char_mode then
            break
        end
    end

    -- 將表格轉換為字符串
    for i, chars in pairs(fullAuxCodes) do
        fullAuxCodes[i] = table.concat(table_keys(chars), "")
    end

    return fullAuxCodes
end

-----------------------------------------------
-- 判斷 auxStr 是否匹配 fullAux
-----------------------------------------------
function AuxFilter.match(fullAux, auxStr)
    if #fullAux == 0 then
        return false
    end

    local firstKeyMatched = fullAux[1]:find(auxStr:sub(1, 1)) ~= nil
    -- 如果辅助码只有一个键，且第一个键匹配，则返回 true
    if #auxStr == 1 then
        return firstKeyMatched
    end

    -- 如果辅助码有两个或更多键，检查第二个键是否匹配
    local secondKeyMatched = fullAux[2] and fullAux[2]:find(auxStr:sub(2, 2)) ~= nil

    -- 只有当第一个键和第二个键都匹配时，才返回 true
    return firstKeyMatched and secondKeyMatched
end

function string.starts(haystack, needle)
    return string.sub(haystack, 1, string.len(needle)) == needle
end

function passthrough(input, env)
    for cand in input:iter() do
        yield(cand)
    end
end

function AuxFilter.get_show_auxcode_hint(env, ctx, has_trigger_key)
    local show_auxcode_hint = env.show_auxcode_hint
    if show_auxcode_hint == "option" then
        show_auxcode_hint = "always"
        local auxcode_hint_types = {"always", "on_trigger", "never"}
        for _, hint_type in ipairs(auxcode_hint_types) do
            if ctx:get_option("aux_code_hint_" .. hint_type) then
                show_auxcode_hint = hint_type
                break
            end
        end
    end

    if show_auxcode_hint == "always" then
        return true
    elseif show_auxcode_hint == "on_trigger" then
        return has_trigger_key
    elseif show_auxcode_hint == "never" then
        return false
    end
end

function AuxFilter.get_show_nonmatch(env, ctx)
    if env.nonmatch_policy == "option" then
        return ctx:get_option("aux_code_nonmatch_policy")
    end

    return env.nonmatch_policy == "prioritize"
end

function AuxFilter.get_single_char_mode(env, ctx)
    if env.filter_mode == "option" then
        return ctx:get_option("aux_code_single_char")
    end

    return env.filter_mode == "single"
end

------------------
-- filter 主函數 --
------------------
function AuxFilter.func(input, env)
    local context = env.engine.context
    local inputCode = context.input

    -- 過濾忽略的輔助碼
    if #env.ignore_regex > 0 and string.find(inputCode, env.ignore_regex) then
        return passthrough(input, env)
    end

    -- 分割部分正式開始
    local auxStr = ''
    local has_trigger_key = false

    -- 判断字符串中是否包含輔助碼分隔符
    if string.find(inputCode, env.trigger_key) then
        has_trigger_key = true
        -- 字符串中包含輔助碼分隔符
        local trigger_pattern = env.trigger_key:gsub("%W", "%%%1") -- 處理特殊字符
        local localSplit = inputCode:match(trigger_pattern .. "([^,]+)")
        if localSplit then
            auxStr = string.sub(localSplit, 1, 2)
            -- log.info('re.match ' .. local_split)
        end
    end

    local show_auxcode_hint = AuxFilter.get_show_auxcode_hint(env, context, has_trigger_key)
    local show_nonmatch = AuxFilter.get_show_nonmatch(env, context)
    local single_char_mode = AuxFilter.get_single_char_mode(env, context)

    local insertLater = {}

    -- 遍歷每一個待選項
    for cand in input:iter() do
        local auxCodes = AuxFilter.aux_code[cand.text] -- 僅單字非 nil
        local fullAuxCodes = AuxFilter.fullAux(env, cand.text, single_char_mode)

        -- 查看 auxCodes
        -- log.info(cand.text, #auxCodes)
        -- for i, cl in ipairs(auxCodes) do
        --     log.info(i, table.concat(cl, ',', 1, #cl))
        -- end

        -- 給待選項加上輔助碼提示
        if show_auxcode_hint and auxCodes and #auxCodes > 0 then
            local codeComment = table.concat(auxCodes, ',')
            -- 處理 simplifier
            if cand:get_dynamic_type() == "Shadow" then
                local shadowText = cand.text
                local shadowComment = cand.comment
                local originalCand = cand:get_genuine()
                cand = ShadowCandidate(originalCand, originalCand.type, shadowText,
                    originalCand.comment .. shadowComment .. '(' .. codeComment .. ')')
            else
                cand.comment = '(' .. codeComment .. ')'
            end
        end

        -- 過濾輔助碼
        if #auxStr == 0 then
            -- 沒有輔助碼、不需篩選，直接返回待選項
            yield(cand)
        elseif #auxStr > 0 and fullAuxCodes and (cand.type == 'user_phrase' or cand.type == 'phrase') and
            AuxFilter.match(fullAuxCodes, auxStr) then
            -- 匹配到辅助码的待选项，直接插入到候选框中( 获得靠前的位置 )
            yield(cand)
        elseif show_nonmatch then
            -- 沒有匹配上的待選項，留到最後再插入
            table.insert(insertLater, cand)
        end

    end

    -- 插入沒有匹配上的待選項
    if show_nonmatch then
        for _, cand in ipairs(insertLater) do
            yield(cand)
        end
    end
end

function AuxFilter.fini(env)
    env.notifier:disconnect()
end

return AuxFilter

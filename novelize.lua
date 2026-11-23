-- 出力ファイル名を決定
outputFileName = status.filename:match("[^%./]+") .. "LuaOutput.log"
os.remove(outputFileName)

-- デフォルトの除外パターン
local default_exclude_patterns = {
    "^%s*%%",
    "^%s*\\directlua",
    "^%s*\\par",
    "^%s*\\newcommand",
    "^%s*\\renewcommand",
    "^%s*\\vspace{.+}$",
    "^%s*\\vfil[l]?[l]?$",
    "^%s*\\input",
    "^%s*\\include",
    "^%s*\\%a-part",
    "^%s*\\%a-chapter",
    "^%s*\\%a-section",
    "^%s*\\%a-subsection",
    "^%s*\\%a-subsubsection",
    "^%s*\\%a-Heading",
    "^%s*\\pagestyle",
    "^%s*\\%a-PageStyle",
    "^%s*\\newpage",
    "^%s*\\clearpage",
    "^%s*\\setcounter"
}

--=========================================================
--  ユーティリティ
--=========================================================

---------------------------------------------------------
--  \コマンド{...}[...] のような並びをまとめて {} で包む
--  例: "\tatechuyoko{18}時" -> "{\tatechuyoko{18}}時"
--       "\ruby{a}{b}text"   -> "{\ruby{a}{b}}text"
---------------------------------------------------------
local function wrap_embedded_commands(s)
    local result = {}
    local pos = 1

    while true do
        local cmd_start, cmd_end = s:find('\\%a+', pos)
        if not cmd_start then
            table.insert(result, s:sub(pos))
            break
        end
        -- コマンド手前のテキストはそのまま
        table.insert(result, s:sub(pos, cmd_start - 1))

        -- コマンド名の直後に続く {...} や [...] を可能な限り連続して取り込む
        local scan_pos = cmd_end + 1
        local arg_end = cmd_end
        while true do
            local ch = s:sub(scan_pos, scan_pos)
            if ch == '{' then
                local b_start, b_end = s:find('%b{}', scan_pos)
                if b_start == scan_pos then
                    arg_end = b_end
                    scan_pos = b_end + 1
                else
                    break
                end
            elseif ch == '[' then
                local b_start, b_end = s:find('%b[]', scan_pos)
                if b_start == scan_pos then
                    arg_end = b_end
                    scan_pos = b_end + 1
                else
                    break
                end
            else
                break
            end
        end

        table.insert(result, '{' .. s:sub(cmd_start, arg_end) .. '}')
        pos = arg_end + 1
    end

    return table.concat(result)
end

---------------------------------------------------------
--  replace_fonts の書式チェック
--  期待する形式: { {'パターン', '\\フォントコマンド'}, ... }
--  （順序を保証するため、キー・値形式ではなく配列形式で受け取る）
---------------------------------------------------------
local function validate_replace_fonts(rules)
    -- 配列部分の要素数と全要素数が違えば、キー・値形式が混ざっている
    local total = 0
    for _ in pairs(rules) do
        total = total + 1
    end
    if total ~= #rules then
        error("novelize: replace_fonts は { {'パターン', '\\\\フォント'}, ... } の配列形式で指定してください"
              .. "（['パターン'] = 'フォント' のキー・値形式は使えません）")
    end
    for i, rule in ipairs(rules) do
        if type(rule) ~= "table" or type(rule[1]) ~= "string" or type(rule[2]) ~= "string" then
            error("novelize: replace_fonts の " .. i .. " 番目の要素は {'パターン', '\\\\フォント'} の形式で指定してください")
        end
    end
    return rules
end

---------------------------------------------------------
--  ユーザー設定にデフォルト値をマージした config を構築する
---------------------------------------------------------
local function build_config(user_config)
    return {
        auto_number_tatechuyoko = (user_config.auto_number_tatechuyoko == true), -- デフォルトは false
        auto_exclamation_space = (user_config.auto_exclamation_space == true),  -- デフォルトは false
        exclude_patterns = user_config.exclude_patterns or default_exclude_patterns,
        replace_fonts = validate_replace_fonts(user_config.replace_fonts or {}), -- 未指定なら空 = 機能OFF
        output_log = (user_config.output_log ~= false),                        -- デフォルトは true
    }
end

--=========================================================
--  ① 段落処理（\par 付与・環境スキップ・空行処理）
--=========================================================

---------------------------------------------------------
--  \begin/\end 環境のスキップ、\defaultfontfeatures 内のスキップ、
--  除外パターン判定、\par / \vspace の付与を行う。
--  process_lines / in_defaultfontfeatures はコールバック間で
--  保持される必要があるため、state テーブル経由で読み書きする。
---------------------------------------------------------
local function process_paragraph_and_environment(line, config, state)
    -- \defaultfontfeatures 開始検出
    if line:match("^%s*\\defaultfontfeatures") then
        state.in_defaultfontfeatures = true
    end

    if state.process_lines then
        if line:match("^%s*\\begin{.-}.-\\end{.-}%s*$") then
            -- begin...end のみの単一行は何もしない
        elseif line:match("^%s*\\begin") then
            state.process_lines = false
        else
            ---------------------------------------------------------
            -- 除外パターン判定
            ---------------------------------------------------------
            local is_excluded = false
            for _, pattern in ipairs(config.exclude_patterns) do
                if line:match(pattern) then
                    is_excluded = true
                    break
                end
            end
            ---------------------------------------------------------
            -- 空行 & 改行処理
            ---------------------------------------------------------
            if is_excluded or state.in_defaultfontfeatures then
                -- そのまま（\par を付けない）
            elseif line:match("^%s*$") then
                line = line .. "\\vspace{\\baselineskip}"
            else
                line = "\\par " .. line
            end
        end
        -- \defaultfontfeatures 終了検出（行頭が空白のみ＋ }）
        if state.in_defaultfontfeatures and line:match("^%s*}%s*$") then
            state.in_defaultfontfeatures = false
        end
    elseif line:match("^%s*\\end") then
        state.process_lines = true
    end

    return line
end

--=========================================================
--  ② 文字置換
--=========================================================

---------------------------------------------------------
--  エスケープされた二重山括弧を luatexja-otf の表記に書き換える
---------------------------------------------------------
local function convert_escaped_brackets(line)
    line = unicode.utf8.gsub(line, '｜《', '\\UTF{300A}')
    line = unicode.utf8.gsub(line, '｜》', '\\UTF{300B}')
    return line
end

---------------------------------------------------------
--  ！？の連続を自動縦中横化
---------------------------------------------------------
local function auto_tatechuyoko_symbols(line)
    line = unicode.utf8.gsub(line, '[!！?？][!！?？][!！?？]?', function (s)
        s = unicode.utf8.gsub(s, '！', '!')
        s = unicode.utf8.gsub(s, '？', '?')
        return s
     end)
    line = unicode.utf8.gsub(line, '([!?][!?][!?]?)', '\\tatechuyoko{%1}')
    line = unicode.utf8.gsub(line, '(.+)［＃「%1」は縦中横］', '\\tatechuyoko{%1}')
    line = unicode.utf8.gsub(line, '［＃縦中横］(.-)［＃縦中横終わり］', '\tatechuyoko{%1}')
    return line
end

---------------------------------------------------------
--  数字の自動縦中横化（config.auto_number_tatechuyoko が true の時のみ）
---------------------------------------------------------
local function auto_tatechuyoko_numbers(line, config)
    if not config.auto_number_tatechuyoko then
        return line
    end

    local protected = {}
    local base = 0xF0000
    local idx = 0

    -- ① 既存のLaTeXコマンドを退避
    line = unicode.utf8.gsub(line, '\\%a+%b{}', function(m)
        idx = idx + 1
        local key = unicode.utf8.char(base + idx)
        protected[key] = m
        return key
    end)
    -- ② 本文処理
    line = unicode.utf8.gsub(
        line,
        '([^0-9])([0-9][0-9])([^0-9])',
        '%1\\tatechuyoko{%2}%3'
    )
    -- ③ 復元
    for k, v in pairs(protected) do
        line = unicode.utf8.gsub(line, k, v)
    end

    return line
end

---------------------------------------------------------
--  自動感嘆符・疑問符後のスペース（config.auto_exclamation_space が true の時のみ）
---------------------------------------------------------
local function apply_exclamation_space(line, config)
    if not config.auto_exclamation_space then
        return line
    end

    line = unicode.utf8.gsub(line, '(\\tatechuyoko{[!！?？][!！?？][!！?？]?})([^\u{fffff}　…―（）〔〕［］｛｝〈〉《》「」『』【】｟｠〘〙〖〗«»〝〟])', '%1　%2')
    line = unicode.utf8.gsub(line, '([！？‼⁇⁈⁉])([^\u{fffff}　…―（）〔〕［］｛｝〈〉《》「」『』【】｟｠〘〙〖〗«»〝〟])', '%1　%2')

    return line
end

---------------------------------------------------------
--  傍点
---------------------------------------------------------
local function convert_kenten(line)
    local function kenten_wrap(content)
        return '\\kenten{' .. wrap_embedded_commands(content) .. '}'
    end

    line = unicode.utf8.gsub(line, '《《(.-)》》', kenten_wrap)
    line = unicode.utf8.gsub(line, '(.+)［＃「%1」に傍点］', kenten_wrap)
    line = unicode.utf8.gsub(line, '［＃傍点］(.-)［＃傍点終わり］', kenten_wrap)

    -- \kenten{...}[opt] -> \kenten[opt]{...}（中身に {} が含まれても対応できるよう %b{} で取得）
    line = line:gsub('\\kenten(%b{})%[([%a]+)%]', function(braced, opt)
        return '\\kenten[' .. opt .. ']' .. braced
    end)

    return line
end

---------------------------------------------------------
--  ルビ
---------------------------------------------------------
local function convert_ruby(line)
    local function ruby_wrap(oya, yomi)
        return '\\ruby{' .. wrap_embedded_commands(oya) .. '}{' .. wrap_embedded_commands(yomi) .. '}'
    end

    line = unicode.utf8.gsub(line, '｜([^《》]-)《([^《》]-)》', ruby_wrap)
    line = unicode.utf8.gsub(line, '([\u{2e80}-\u{2fdf}\u{3400}-\u{4dbf}\u{4e00}-\u{9fff}\u{f900}-\u{faff}\u{20000}-\u{3ffff}々〇〻ゝゞ〱〲]+)《([^《》]-)》', ruby_wrap)

    -- \ruby{...}{...}[opt] -> \ruby[opt]{...}{...}（中身に {} が含まれても対応できるよう %b{} で取得）
    line = line:gsub('\\ruby(%b{})(%b{})%[([%a:%.%*!|<>%(%)]-)%]', function(oya, yomi, opt)
        return '\\ruby[' .. opt .. ']' .. oya .. yomi
    end)

    return line
end

---------------------------------------------------------
--  パターンに一致した部分を {フォント 一致部分} で包む
--  config.replace_fonts の各ルールを、記述された順に適用する。
--  （空の場合は何もしない）
--  注意: ルールは順番に line 全体へ適用されるため、後のルールは
--        前のルールが挿入した {\フォント ...} も対象として見る。
--        パターンにキャプチャ ( ) を含めると一致部分の一部しか
--        包まれなくなるので、含めないこと。
---------------------------------------------------------
local function apply_font_replacements(line, config)
    for _, rule in ipairs(config.replace_fonts) do
        local pattern, font = rule[1], rule[2]
        line = unicode.utf8.gsub(line, pattern, function(s)
            return '{' .. font .. ' ' .. s .. '}'
        end)
    end
    return line
end

--=========================================================
--  ③ ログ出力
--=========================================================
local function write_log(line, config)
    if not config.output_log then
        return
    end
    local file = io.open(outputFileName, "a")
    file:write(line .. "\n")
    file:close()
end

--=========================================================
--  ユーザー設定を保持した novelize を生成するクロージャ
--=========================================================
function make_novelize(user_config)
    local config = build_config(user_config)

    -- コールバック間で保持される必要がある状態
    local state = {
        process_lines = true,
        in_defaultfontfeatures = false,
    }

    ---------------------------------------------------------
    --  実際に callback に登録される関数（line を受け取る）
    ---------------------------------------------------------
    local function novelize_closure(line)
        -- ① 段落処理（\par 付与・環境スキップ・空行処理）
        line = process_paragraph_and_environment(line, config, state)

        -- ② 文字置換
        line = convert_escaped_brackets(line)
        line = auto_tatechuyoko_symbols(line)
        line = auto_tatechuyoko_numbers(line, config)
        line = apply_exclamation_space(line, config)
        line = convert_kenten(line)
        line = convert_ruby(line)
        line = apply_font_replacements(line, config)

        ---------------------------------------------------------
        -- 拡張コードをここに書く
        ---------------------------------------------------------

        ---------------------------------------------------------
        -- 拡張コードここまで
        ---------------------------------------------------------

        -- ③ ログ出力（ユーザーがオフにできる）
        write_log(line, config)

        return line
    end

    return novelize_closure
end

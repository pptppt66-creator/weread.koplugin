--[[--
划线上传 UI 控制器

在 KOReader 划线弹窗中注入「同步到微信读书」按钮，
点击后先保存 KOReader 本地划线，再同步到微信读书云端。

作为 Mixin 注册到 WeReadPlugin（在 main.lua 的 Mixin.apply 中引入）。
注意：Mixin 不允许重复方法名，本模块不定义 onReaderReady
（已被 weread.lib.reader_lifecycle 占用），改用 init 延迟轮询注册。
]]

local UIManager = require("ui/uimanager")
local Notification = require("ui/widget/notification")
local logger = require("weread.lib.logger")
local PluginUtil = require("weread.lib.plugin_util")
local HighlightUpload = require("weread.lib.highlight_upload")

local _ = PluginUtil.tr
local T = PluginUtil.T

local M = {}

--- 注入划线弹窗按钮（ui.highlight 可用后调用）
function M:_registerHighlightUploadButton()
    local highlight = self.ui and self.ui.highlight
    if not highlight or type(highlight.addToHighlightDialog) ~= "function" then
        return false
    end
    if self._highlight_upload_button_registered then
        return true
    end

    -- 插入到弹窗按钮列表末尾（13号，在 12_search 之后）
    -- 使用字符串 idx 与 KOReader 内置按钮保持一致，避免排序异常
    highlight:addToHighlightDialog("13_sync_weread", function(this, idx)
        local plugin = this.weread_plugin or self
        local text = this.selected_text and this.selected_text.text
        local has_text = type(text) == "string" and text ~= ""
        return {
            text = _("同步微读"),
            enabled = has_text,
            callback = function()
                -- 【关键修复】：必须在 onClose 之前触发 KOReader 原生划线，
                -- 否则 onClose(true) 会清空当前页面的文本选择上下文 (selection context)
                if this.selected_text then
                    pcall(function()
                        local ui = (plugin and plugin.ui) or this.ui
                        local hl = ui and ui.highlight
                        if hl then
                            if type(hl.onSaveHighlight) == "function" then
                                hl:onSaveHighlight(this.selected_text)
                            elseif type(hl.addHighlight) == "function" then
                                hl:addHighlight(this.selected_text)
                            end
                        end
                    end)
                end

                if type(this.onClose) == "function" then
                    this:onClose(true)
                end
                M._doHighlightUpload(plugin, this)
            end,
        }
    end)

    self._highlight_upload_button_registered = true
    logger.info("highlight_upload: button registered")
    return true
end

--- 插件初始化时启动轮询，等 ui.highlight 可用后注册按钮
function M:_initHighlightUpload()
    if self._highlight_upload_poll_started then return end
    self._highlight_upload_poll_started = true

    local session_gen = self._reader_session_gen or 0
    local attempts = 0
    local max_attempts = 120  -- 最多轮询 120 秒（每 1 秒一次）
    local function tryRegister()
        attempts = attempts + 1
        -- 阅读器会话已变更且已注册成功则停止
        if (self._reader_session_gen or 0) ~= session_gen
            and self._highlight_upload_button_registered then
            return
        end
        if not self:_registerHighlightUploadButton() then
            if attempts < max_attempts then
                UIManager:scheduleIn(1.0, tryRegister)
            else
                logger.info("highlight_upload: gave up waiting for ui.highlight")
            end
        end
    end
    UIManager:scheduleIn(0.5, tryRegister)
end

--- 执行同步（异步，避免阻塞 UI）
function M._doHighlightUpload(plugin, highlight_dialog)
    local text = highlight_dialog.selected_text
        and highlight_dialog.selected_text.text
    if not text or text == "" then
        UIManager:show(Notification:new{
            text = _("无法获取划线内容"),
            timeout = 3,
        })
        return
    end

    UIManager:show(Notification:new{
        text = _("已保存本地，正在同步到微信读书…"),
        timeout = 2,
    })

    UIManager:scheduleIn(0.1, function()
        local ok, err = HighlightUpload.sync(plugin, highlight_dialog)
        if ok then
            UIManager:show(Notification:new{
                text = _("已成功同步至微信读书"),
                timeout = 3,
            })
        else
            logger.warn("highlight_upload failed:", tostring(err))
            UIManager:show(Notification:new{
                text = T(_("本地已划线，但云端同步失败：%1"), tostring(err or "未知错误")),
                timeout = 5,
            })
        end
    end)
end

return M
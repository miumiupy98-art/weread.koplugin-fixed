local I18n = require("lib.i18n")

local function _(text)
    return I18n.tr(text)
end

return {
    fullname = _("WeRead"),
    description = _([[Browse and download WeRead books and public-account articles, with QR login, annotations, footnotes, and OTA updates.]]),
    version = "0.3.5",
}

require "lib.moonloader"

local function safeRequire(moduleName)
    local success, module = pcall(require, moduleName)
    if not success then
        print("Error: Librería faltante - " .. moduleName)
        thisScript():unload()
        return nil
    end
    return module
end

local sampev = safeRequire("lib.samp.events")
local https = safeRequire("ssl.https")
local ltn12 = safeRequire("ltn12")
local json = safeRequire("cjson")
local inicfg = safeRequire("inicfg")

local streamedPlayers = {}
local radiusThreshold = 300
local drawTime = 0
local isRendering = false
local playerScreenX, playerScreenY = nil, nil
local closestPlayerId = nil
local faceOffset = 0.8
local notionToken = ""
local dbPeople = "ec0b82fc25cd416cac75beee549226e5"
local dbRank = "1b98587efd8f804fa385d6508d126434"
local dbOrg = "f15cf745b38442ebabfb04613360e048"
local dbMem = "97459dcda7254108bc1dfe022789354c"
local cuentasTable = {}
memSAEF = {}
local originalTargetTime = 0
local successfulScan = false
local playerInfoPrinted = false
local scannedNicknames = {}

local config = inicfg.load(nil, "facerecon.ini")

if not config then
    config = inicfg.load({
        Notion = {
            SECRET = "Solicitar Secret"
        },
        Key = {
            Key_1 = 66
        }
    }, "facerecon.ini")
    inicfg.save(config, "facerecon.ini")
end

local vkey_1 = config.Key.KEY_1

local function xor(a, b)
    return string.char(bit.bxor(string.byte(a), string.byte(b)))
end

local function from_hex(hex)
    return (hex:gsub('..', function(cc) return string.char(tonumber(cc, 16)) end))
end

local function decrypt(encryptedHex, key)
    local encrypted = from_hex(encryptedHex)
    local decrypted = {}
    local keyLength = #key
    for i = 1, #encrypted do
        local keyChar = key:sub((i - 1) % keyLength + 1, (i - 1) % keyLength + 1)
        decrypted[i] = xor(encrypted:sub(i, i), keyChar)
    end
    return table.concat(decrypted)
end

local encryptedSecret = config.Notion.SECRET
local password = "Khub86XL357d1qI83Ss3rv48P"
notionToken = decrypt(encryptedSecret, password)

function fetchNotionData()
    local headers = {
        ["Authorization"] = "Bearer " .. notionToken,
        ["Content-Type"] = "application/json",
        ["Notion-Version"] = "2022-06-28"
    }
    local function queryDatabase(databaseId)
        local url = "https://api.notion.com/v1/databases/" .. databaseId .. "/query"
        local response = {}
        local _, code = https.request({
            url = url,
            method = "POST",
            headers = headers,
            source = ltn12.source.string(json.encode({ page_size = 100 })),
            sink = ltn12.sink.table(response)
        })
        return code == 200 and json.decode(table.concat(response)) or nil
    end
    local peopleData = queryDatabase(dbPeople)
    local rankData = queryDatabase(dbRank)
    local orgData = queryDatabase(dbOrg)
    local memData = queryDatabase(dbMem)
    if not peopleData or not rankData or not orgData or not memData then return end
    local peopleMap, assignedRanks, orgMap = {}, {}, {}
    memSAEF = {}
    for _, org in ipairs(orgData.results) do
        local orgId = org.id
        local nombre = org.properties["Nombre"] and org.properties["Nombre"].title[1] and org.properties["Nombre"].title[1].text.content or ""
        if nombre ~= "" then
            orgMap[orgId] = nombre
        end
    end
    for _, person in ipairs(peopleData.results) do
        local cuenta = person.properties["Cuenta"] and person.properties["Cuenta"].rich_text[1] and person.properties["Cuenta"].rich_text[1].text.content or ""
        local organizacionId = person.properties["Organizacion"] and person.properties["Organizacion"].relation[1] and person.properties["Organizacion"].relation[1].id or ""
        local organizacion = organizacionId ~= "" and orgMap[organizacionId] or ""
        if cuenta ~= "" then
            peopleMap[person.id] = cuenta
            assignedRanks[cuenta] = { Rango = "N/A", Organizacion = organizacion }
        end
    end
    for _, rank in ipairs(rankData.results) do
        local rango = rank.properties["Rango"] and rank.properties["Rango"].title[1] and rank.properties["Rango"].title[1].text.content or ""
        local individuos = rank.properties["Individuos"] and rank.properties["Individuos"].relation or {}
        for _, individuo in ipairs(individuos) do
            local cuenta = peopleMap[individuo.id]
            if cuenta then
                assignedRanks[cuenta].Rango = rango
            end
        end
    end
    for _, entry in ipairs(memData.results) do
        local cuenta = entry.properties["Cuenta"] and entry.properties["Cuenta"].formula and entry.properties["Cuenta"].formula.string or ""
        if cuenta ~= "" then
            table.insert(memSAEF, cuenta)
        end
    end
    cuentasTable = {}
    for cuenta, data in pairs(assignedRanks) do
        table.insert(cuentasTable, { Cuenta = cuenta, Rango = data.Rango, Organizacion = data.Organizacion })
    end
end

fetchNotionData()

function sampev.onPlayerStreamIn(playerId)
    streamedPlayers[playerId] = true
end

function sampev.onPlayerStreamOut(playerId)
    streamedPlayers[playerId] = nil
end

scanningActive = false

function findCenterPlayer()
    local sx, sy = getScreenResolution()
    local centerX, centerY = sx / 2, sy / 2
    local closestPlayer, minDistance = nil, math.huge
    for playerId in pairs(streamedPlayers) do
        local result, player = sampGetCharHandleBySampPlayerId(playerId)
        if result and player and isCharOnScreen(player) then
            local x, y, z = getCharCoordinates(player)
            local screenX, screenY = convert3DCoordsToScreen(x, y, z)
            if screenX and screenY then
                local px, py, pz = getCharCoordinates(PLAYER_PED)
                if not isCharInAnyCar(player) and isLineOfSightClear(px, py, pz, x, y, z, true, true, false, false, false) then
                    local distToCenter = math.sqrt((centerX - screenX)^2 + (centerY - screenY)^2)
                    if distToCenter < minDistance then
                        minDistance = distToCenter
                        closestPlayer = playerId
                        playerScreenX, playerScreenY = screenX, screenY
                    end
                end
            end
        end
    end
    if closestPlayer and minDistance <= radiusThreshold then
        local nickname = sampGetPlayerNickname(closestPlayer):lower()
        local scanTime = 3.0
        if scannedNicknames[nickname] then
            scanTime = 1.0
        end
        printStringNow("~g~Escaneo en proceso...", scanTime * 1000)
        originalTargetTime = os.clock() + scanTime
        drawTime = originalTargetTime + 2.0
        closestPlayerId = closestPlayer
        successfulScan = false
        playerInfoPrinted = false
        scanningActive = true
        lua_thread.create(function()
            local targetTime = originalTargetTime
            while os.clock() < targetTime do
                wait(0)
                if not isKeyDown(0x02) then
                    printStringNow("~r~Escaneo interrumpido.", 1500)
                    drawTime = 0
                    closestPlayerId = nil
                    playerScreenY, playerScreenX = nil, nil
                    scanningActive = false
                    isRendering = false
                    return
                end
                local result, player = sampGetCharHandleBySampPlayerId(closestPlayerId)
                if result and player then
                    local px, py, pz = getCharCoordinates(PLAYER_PED)
                    local x, y, z = getCharCoordinates(player)
                    if not isLineOfSightClear(px, py, pz, x, y, z, true, true, false, false, false) or not isCharOnScreen(player) then
                        printStringNow("~r~Escaneo interrumpido.", 1500)
                        drawTime = 0
                        closestPlayerId = nil
                        playerScreenY, playerScreenX = nil, nil
                        scanningActive = false
                        isRendering = false
                        return
                    end
                end
            end
            successfulScan = true
            scannedNicknames[nickname] = true
            scanningActive = false
        end)        
    else
        printStringNow("~r~No se encuentra jugador.", 1500)
        drawTime = 0
        closestPlayerId = nil
        playerScreenX, playerScreenY = nil, nil
    end
end

function startRenderingLoop()
    lua_thread.create(function()
        while isRendering do
            wait(0)
            onRender()
        end
    end)
end

function onRender()
    if closestPlayerId then
        local result, player = sampGetCharHandleBySampPlayerId(closestPlayerId)
        if result and player then
            local x, y, z = getCharCoordinates(player)
            local screenX, screenY = convert3DCoordsToScreen(x, y, z)
            if screenX and screenY then
                playerScreenX, playerScreenY = screenX, screenY
                local sx, sy = getScreenResolution()
                local boxSize = 200
                local boxX, boxY = playerScreenX - boxSize / 2, playerScreenY - boxSize / 2
                local borderSize = 3
                local borderColor = 0xFFFF0000
                local transparentColor = 0x00000000
                renderDrawBoxWithBorder(boxX, boxY, boxSize, boxSize, transparentColor, borderSize, borderColor)
            end
        end
    end
    if successfulScan and not playerInfoPrinted and os.clock() >= originalTargetTime and closestPlayerId then
        local nickname = sampGetPlayerNickname(closestPlayerId):lower()
        local registered, rango, organizacion = false, "N/A", ""
        for _, cuenta in ipairs(cuentasTable) do
            if nickname == cuenta.Cuenta:lower() then
                registered = true
                rango = cuenta.Rango ~= "N/A" and cuenta.Rango or "N/A"
                organizacion = cuenta.Organizacion ~= "" and cuenta.Organizacion or ""
                break
            end
        end
        local status = registered and "" or " ~r~(( No registrado ))"
        local printText = string.format("Nombre: ~b~%s~w~ - ID: ~b~%d~w~%s", sampGetPlayerNickname(closestPlayerId), closestPlayerId, status)
        if organizacion ~= "" then
            printText = printText .. "~n~Entidad: ~b~" .. organizacion .. "~w~ - Rango: ~b~" .. rango
        end
        printStringNow(printText, 2000)
        local chatText = string.format("[F.R] {FFFFFF}Nombre: {3399FF}%s {3399FF}(%d){FFFFFF}%s", sampGetPlayerNickname(closestPlayerId), closestPlayerId, status:gsub("~r~", "{FF0000}"))
        if organizacion ~= "" then
            chatText = chatText .. string.format("  Entidad: {3399FF}%s{FFFFFF}  Rango: {3399FF}%s", organizacion, rango)
        end
        sampAddChatMessage(chatText, 0x3399FF)
        playerInfoPrinted = true
    end
    if not scanningActive and os.clock() >= drawTime then
        isRendering = false
        closestPlayerId = nil
        drawTime = 0
    end
end

function isPlayerVerified()
    local vIp = "144.217.123.12"
    local result, pId = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if result then
        local pName = sampGetPlayerNickname(pId)
        local sIp, sPort = sampGetCurrentServerAddress()
        for _, cuenta in ipairs(memSAEF) do
            if cuenta == pName and sIp == vIp then
                return true
            end
        end
    else
        return false
    end
end

function main()
    while not isSampAvailable() do wait(100) end
    while not sampIsLocalPlayerSpawned() do wait(10) end
    if not isPlayerVerified() then
        sampAddChatMessage("[F.R]{FFFFFF} Intentaste acceder a sistemas privados sin el permiso de acceso necesario, {FFFF00}la policía será notificada{FFFFFF}.", 0x3399FF)
        thisScript():unload()
    else
        sampAddChatMessage("[F.R]{FFFFFF} Equipo de reconocimiento facial functional. Utiliza tu {3399FF}cámara{FFFFFF} o {3399FF}francotirador{FFFFFF} para activarlo.", 0x3399FF)
    end
    sampRegisterChatCommand("factualizar", fetchNotionData)
    while true do
        wait(0)
        if not sampIsChatInputActive() and not sampIsDialogActive() then
            local weapon = getCurrentCharWeapon(PLAYER_PED)
            if (weapon == 43 or weapon == 34) and isKeyDown(0x02) then
                if isKeyJustPressed(vkey_1) then
                    findCenterPlayer()
                end
                if not isRendering then
                    isRendering = true
                    startRenderingLoop()
                end
            else
                drawTime = 0
                isRendering = false
            end
        end
    end
end

function(require, repo)
    -- CC: Tweaked DFPWM Playlist with Stop, Loop, Shuffle, and Adaptive Buttons (Clickable aligned)
    
    local dfpwm = require("cc.audio.dfpwm")
    local speakers = { peripheral.find("speaker") }
    if not peripheral.find("speaker") then error("No speaker(s) attached") end
    
    -- Terminal setup
    local mon = peripheral.find("monitor")
    if mon then
        term.redirect(mon)
        if mon.setTextScale then mon.setTextScale(1) end
        mon.clear()
    end
    
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    
    -- ===== Songs setup =====
    local songIndexUrl = "https://raw.githubusercontent.com/" .. repo .. "/refs/heads/main/index.txt"
    local songNames = textutils.unserialize(http.get(songIndexUrl).readAll())
    local songs = {}
    for i, name in ipairs(songNames) do
        table.insert(songs, {
            name = name,
            fn = function()
                local url = "https://raw.githubusercontent.com/" .. repo .. "/refs/heads/main/" .. name:gsub(" ", "%%20") .. ".dfpwm"
                return http.get(url).readAll()
            end
        })
    end
    
    -- ===== Playback state =====
    local savedName = settings.get("currentSong", nil)
    local currentSong = nil
    
    if savedName ~= nil then
        for _, song in ipairs(songs) do
            if song.name == savedName then
                currentSong = song
                break
            end
        end
    end
    
    local playing = settings.get("playing", false)
    local stopFlag = false
    local shuffle = settings.get("shuffle", true)
    local loopMode = settings.get("loopMode", 0) -- 0=Off,1=All,2=One
    local volume = .35
    local decoder = dfpwm.make_decoder()
    local currentPage = settings.get("currentPage", 1)
    local width, height = term.getSize()
    local topRows = 2
    local bottomRows = 5 -- reserve bottom 5 lines
    local songsPerPage = height - topRows - bottomRows
    
    -- Button storage for click detection
    local buttons = {}
    
    -- ===== UI functions =====
    local function totalPages()
        return math.max(1, math.ceil(#songs / songsPerPage))
    end
    
    local function drawUI()
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
    
        -- Now Playing
        term.setCursorPos(2,1)
        term.write("Now Playing: " .. (currentSong and currentSong.name or "(none)"))
    
        -- Song list (paged)
        local startIdx = (currentPage-1)*songsPerPage + 1
        local y = 3
        for i=startIdx, math.min(startIdx+songsPerPage-1, #songs) do
            term.setCursorPos(2,y)
            term.setTextColor((currentSong==songs[i]) and colors.yellow or colors.white)
            term.write(songs[i].name)
            y = y + 1
        end
    
        -- Reserve a blank line
        y = y + 1
    
        -- Bottom controls (4 lines)
        buttons = {} -- reset button list
        local btnLines = {
            {"Shuffle: "..(shuffle and "On" or "Off"), "Loop: "..({[0]="Off",[1]="All",[2]="One"})[loopMode]},
            {"Page "..currentPage.."/"..totalPages(), "Prev","Next"},
            {(playing and "Playing" or "Stopped"), "Skip"},
            {"-","Volume: "..math.floor(volume*100).."%","+",""}
        }
    
        local startY = height - bottomRows + 1
        for lineIdx, line in ipairs(btnLines) do
            local x = 2
            local y = startY + lineIdx - 1
            for i, btn in ipairs(line) do
                if #btn>0 then
                    local btnStartX = x
                    term.setCursorPos(btnStartX,y)
                    term.setBackgroundColor(colors.gray)
                    term.setTextColor(colors.white)
                    term.write(" "..btn.." ")
                    local btnEndX = btnStartX + #btn + 1
                    -- Store button for click detection
                    table.insert(buttons,{
                        line=lineIdx, text=btn, x1=btnStartX, x2=btnEndX
                    })
                    x = btnEndX + 2
                end
            end
        end
    end
    
    -- ===== Playback loop =====
    local function playerLoop()
        while true do
            if currentSong and playing then
                local songData = currentSong.fn()
                local dataLen = #songData
                for i = 1, dataLen, 16*1024 do
                    if stopFlag then break end
                    local chunk = songData:sub(i, math.min(i+16*1024-1, dataLen))
                    local buffer = decoder(chunk)
                    local pending = {}
                    
                    for _, spk in pairs(speakers) do
                      if stopFlag then break end
                      if not spk.playAudio(buffer, volume) then
                        pending[peripheral.getName(spk)] = spk
                      end
                    end
                    
                    while not stopFlag and next(pending) do
                      local _, name = os.pullEvent("speaker_audio_empty")
                      local spk = pending[name]
                      if spk and spk.playAudio(buffer, volume) then
                        pending[name] = nil
                      end
                    end
                end
    
                if stopFlag then
                    stopFlag = false
                else
                    -- Auto-advance
                    if loopMode == 2 then
                        -- loop current song
                    elseif shuffle then
                        currentSong = songs[math.random(#songs)]
                    elseif loopMode == 1 then
                        local idx = 1
                        for i,s in ipairs(songs) do if s==currentSong then idx=i end end
                        currentSong = songs[idx % #songs + 1]
                    else
                        local idx = 1
                        for i,s in ipairs(songs) do if s==currentSong then idx=i end end
                        if idx<#songs then currentSong = songs[idx+1] else currentSong = nil playing=false end
                    end
                    settings.set("currentSong", currentSong.name)
                    settings.set("playing", playing)
                    settings.save()
                end
                drawUI()
            else
                os.sleep(0.05)
            end
        end
    end
    
    -- ===== Input loop =====
    local function inputLoop()
        drawUI()
        while true do
            local e, button, x, y = os.pullEvent()
            if e=="mouse_click" then
                -- Song list tap
                local startIdx = (currentPage-1)*songsPerPage + 1
                for i=startIdx, math.min(startIdx+songsPerPage-1, #songs) do
                    local row = 3 + (i-startIdx)
                    if y==row then
                        currentSong = songs[i]
                        stopFlag = true
                        playing = true
                        drawUI()
                    end
                end
    
                -- Bottom controls click detection
                for _, btn in ipairs(buttons) do
                    local btnY = (height - bottomRows + btn.line)
                    if y == btnY and x >= btn.x1 and x <= btn.x2 then
                        -- Identify which button was clicked
                        if btn.text:find("Shuffle") then shuffle = not shuffle
                        elseif btn.text:find("Loop") then loopMode = (loopMode+1)%3
                        elseif btn.text:find("Prev") and currentPage>1 then currentPage=currentPage-1
                        elseif btn.text:find("Next") and currentPage<totalPages() then currentPage=currentPage+1
                        elseif btn.text:find("Stopped") or btn.text:find("Playing") then
                            if playing then
                                -- Pause
                                stopFlag = true
                                playing = false
                            else
                                -- Resume/start
                                if currentSong then
                                    playing = true
                                end
                            end
                        elseif btn.text:find("Skip") then
                            if currentSong then
                                local idx = 1
                                for i,s in ipairs(songs) do if s==currentSong then idx=i end end
                                if shuffle then
                                    currentSong = songs[math.random(#songs)]
                                else
                                    if idx < #songs then
                                        currentSong = songs[idx+1]
                                    else
                                        currentSong = songs[1]
                                    end
                                end
                                stopFlag = true
                                playing = true
                            end
                        elseif btn.text=="-" then volume = math.max(0,volume-0.05)
                        elseif btn.text=="+" then volume = math.min(1,volume+0.05)
                        end
                        drawUI()
                    end
                end

                settings.set("currentPage", currentPage)
                settings.set("loopMode", loopMode)
                settings.set("shuffle", shuffle)
                settings.set("currentSong", currentSong and currentSong.name)
                settings.set("playing", playing)
                settings.save()
            end
        end
    end
    
    parallel.waitForAny(playerLoop, inputLoop)
end

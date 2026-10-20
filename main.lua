local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local player = Player

local isEnemy, estaEnLobby, IsInMatchStrict
local esEnemigoValido, esCuchillo, esPistola, obtenerPistola
local startTargetMonitor, stopTargetMonitor
do
local playerGui = player:WaitForChild("PlayerGui")
local dmvsInvalidateRedirectSelection
local dmvsClearTargetParts
local function dmvsDisconnectConnectionList(list)
    if not list then return end
    for i = #list, 1, -1 do
        local connection = list[i]
        list[i] = nil
        if connection and connection.Connected then connection:Disconnect() end
    end
end
local dmvsIsInfectionMode
local function dmvsIsTargetAlive(target)
    local character = target
    if typeof(target) == "Instance" and target:IsA("Player") then
        character = target.Character
    end
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then return false end
    if dmvsIsInfectionMode and dmvsIsInfectionMode() then
        return character:GetAttribute("InfectionDowned") ~= true
    end
    return humanoid.Health >= 99
end
local function dmvsGetInGameScoreboard()
    local gui = player:FindFirstChild("PlayerGui")
    local main = gui and gui:FindFirstChild("Main")
    local frame = main and main:FindFirstChild("MainGameFrame")
    return frame and frame:FindFirstChild("IngameScore") or nil
end

local dmvsTeamResolverState = {
    Snapshot = {},
    Scoreboard = nil,
    InGame = false,
    LocalGame = nil,
    LastRefresh = 0,
    RefreshInterval = 2,
    Dirty = true,
    WatchConnections = {}
}

local function dmvsInvalidateScoreboard()
    dmvsTeamResolverState.Dirty = true
end

local function dmvsWatchScoreboard(score)
    local state = dmvsTeamResolverState
    if state.Scoreboard == score then return end
    dmvsDisconnectConnectionList(state.WatchConnections)
    state.Scoreboard = score
    if not score then return end
    local watchTeams
    watchTeams = function()
        dmvsInvalidateScoreboard()
        dmvsDisconnectConnectionList(state.WatchConnections)
        state.WatchConnections[#state.WatchConnections + 1] = score.ChildAdded:Connect(watchTeams)
        state.WatchConnections[#state.WatchConnections + 1] = score.ChildRemoved:Connect(watchTeams)
        for _, name in ipairs({"TeamRed", "TeamBlue"}) do
            local folder = score:FindFirstChild(name)
            if folder then
                state.WatchConnections[#state.WatchConnections + 1] = folder.ChildAdded:Connect(dmvsInvalidateScoreboard)
                state.WatchConnections[#state.WatchConnections + 1] = folder.ChildRemoved:Connect(dmvsInvalidateScoreboard)
            end
        end
    end
    watchTeams()
end

local function dmvsRefreshScoreboardTeams(force)
    local state = dmvsTeamResolverState
    local now = os.clock()
    local localGame = player:GetAttribute("Game")
    if not force and not state.Dirty and now - state.LastRefresh < state.RefreshInterval
        and state.LocalGame == localGame
        and (not state.Scoreboard or state.Scoreboard.Parent) then
        return state.Snapshot
    end

    state.LastRefresh = now
    state.LocalGame = localGame
    local snapshot = {}
    local score = dmvsGetInGameScoreboard()
    if score ~= state.Scoreboard then dmvsWatchScoreboard(score) end
    for _, teamName in ipairs({"TeamRed", "TeamBlue"}) do
        local teamFolder = score and score:FindFirstChild(teamName)
        if teamFolder then
            local team = teamName == "TeamRed" and "Red" or "Blue"
            for _, entry in ipairs(teamFolder:GetChildren()) do
                if entry:IsA("GuiObject") then
                    snapshot[string.lower(entry.Name)] = team
                end
            end
        end
    end
    state.Snapshot = snapshot
    state.Dirty = false
    state.InGame = score ~= nil and snapshot[string.lower(player.Name)] ~= nil
    return snapshot
end

local dmvsInfectionRoleAttributes = {"InfectionInfected", "IsInfected", "Infected", "IsZombie", "Zombie"}
local dmvsInfectionModeAttributes = {"GameMode", "MatchMode", "Mode"}
local dmvsInfectionState = {
    Active = false,
    LastRefresh = -math.huge,
    RefreshInterval = 0.4,
    RoleTeams = {},
    Inferred = {},
    Targets = {},
    Converted = {},
    ConvertedAt = {},
    Pending = {},
    LateJoiners = {},
    LastLocalGame = nil,
    LastMatchId = nil,
    HasMatchContext = false,
    RoundEnded = false
}

local function dmvsInfectionReadMarker(holder)
    if not holder then return nil end
    if holder:GetAttribute("InfectionPatientZero") == true then return true end
    local sawSurvivor = false
    for _, name in ipairs(dmvsInfectionRoleAttributes) do
        local value = holder:GetAttribute(name)
        if typeof(value) == "boolean" then
            if value then return true end
            sawSurvivor = true
        elseif typeof(value) == "string" then
            local normalized = value:lower()
            if normalized == "infected" or normalized == "infection" or normalized == "zombie" or normalized == "true" then
                return true
            end
            if normalized == "survivor" or normalized == "human" or normalized == "false" then
                sawSurvivor = true
            end
        end
    end
    if sawSurvivor then return false end
    return nil
end

local function dmvsInfectionHasPatientZero(other)
    if other:GetAttribute("InfectionPatientZero") == true then return true end
    local character = other.Character
    if not character then return false end
    if character:GetAttribute("InfectionPatientZero") == true then return true end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and humanoid:GetAttribute("InfectionPatientZero") == true
end

local function dmvsInfectionAttribute(playerInstance)
    if not playerInstance then return nil end
    local character = playerInstance.Character
    local characterStatus = dmvsInfectionReadMarker(character)
    local playerStatus = dmvsInfectionReadMarker(playerInstance)
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local humanoidStatus = dmvsInfectionReadMarker(humanoid)
    if characterStatus == true or playerStatus == true or humanoidStatus == true then return true end
    if characterStatus == false or playerStatus == false or humanoidStatus == false then return false end
    return nil
end

local function dmvsReadInfectionRoster(teams)
    local frame = playerGui:FindFirstChild("Main")
    frame = frame and frame:FindFirstChild("MainGameFrame")
    if not frame then return end
    local playerFrame = frame:FindFirstChild("PlayersFrame")
    local regularFrame = frame:FindFirstChild("IngameScore")
    local playerNames = {}
    local displayCandidates = {}
    local ambiguousDisplays = {}
    for _, other in ipairs(Players:GetPlayers()) do
        playerNames[other.Name:lower()] = other
        playerNames[tostring(other.UserId)] = other
        local displayKey = other.DisplayName:lower()
        if displayCandidates[displayKey] then ambiguousDisplays[displayKey] = true end
        displayCandidates[displayKey] = other
    end
    for displayKey, other in pairs(displayCandidates) do
        if not ambiguousDisplays[displayKey] and not playerNames[displayKey] then
            playerNames[displayKey] = other
        end
    end
    local function collect(group, team)
        if not group then return end
        for _, entry in ipairs(group:GetChildren()) do
            if entry:IsA("GuiObject") then
                local other = playerNames[entry.Name:lower():gsub("^@", "")]
                if not other then
                    local entryUserId = entry:GetAttribute("UserId")
                    if entryUserId then other = playerNames[tostring(entryUserId)] end
                end
                if not other then
                    for _, sub in ipairs(entry:GetDescendants()) do
                        if sub:IsA("TextLabel") and (sub.Name == "PlayerName" or sub.Name == "TextLabel") then
                            other = playerNames[sub.Text:lower():gsub("^@", "")]
                            if other then break end
                        end
                    end
                end
                if other then teams[other] = team end
            end
        end
    end
    if regularFrame then
        collect(regularFrame:FindFirstChild("TeamRed"), "Red")
        collect(regularFrame:FindFirstChild("TeamBlue"), "Blue")
    end
    if playerFrame then
        collect(playerFrame:FindFirstChild("TeamRedFrame"), "Red")
        collect(playerFrame:FindFirstChild("TeamBlueFrame"), "Blue")
    end
end

local function dmvsClearInfectionRound(ended)
    local state = dmvsInfectionState
    table.clear(state.Converted)
    table.clear(state.ConvertedAt)
    table.clear(state.Pending)
    table.clear(state.LateJoiners)
    table.clear(state.Inferred)
    table.clear(state.Targets)
    table.clear(state.RoleTeams)
    state.Active = false
    state.RoundEnded = ended == true
    state.LastRefresh = -math.huge
    if dmvsInvalidateRedirectSelection then dmvsInvalidateRedirectSelection() end
end

local function dmvsRefreshInfectionState(force)
    local state = dmvsInfectionState
    local now = os.clock()
    local localGame = player:GetAttribute("Game")
    local matchId = player:GetAttribute("MatchId")
    if state.HasMatchContext and (localGame ~= state.LastLocalGame or matchId ~= state.LastMatchId) then
        dmvsClearInfectionRound(false)
    end
    state.HasMatchContext = true
    state.LastLocalGame = localGame
    state.LastMatchId = matchId
    if not force and now - state.LastRefresh < state.RefreshInterval then
        return state
    end
    state.LastRefresh = now
    local regularRoster = dmvsRefreshScoreboardTeams(false)
    local foundPatientZero = false
    local ownCharacter = player.Character
    local myRoot = ownCharacter and ownCharacter:FindFirstChild("HumanoidRootPart")
    local allPlayers = Players:GetPlayers()
    for _, other in ipairs(allPlayers) do
        if dmvsInfectionHasPatientZero(other) then
            local compatible = other == player
            if not compatible then
                compatible = true
                local otherGame = other:GetAttribute("Game")
                local otherMatch = other:GetAttribute("MatchId")
                if localGame ~= nil and localGame ~= ""
                    and otherGame ~= nil and otherGame ~= "" and localGame ~= otherGame then
                    compatible = false
                end
                if (localGame == nil or localGame == "")
                    and otherGame ~= nil and otherGame ~= "" then
                    compatible = false
                end
                if matchId ~= nil and matchId ~= ""
                    and otherMatch ~= nil and otherMatch ~= "" and matchId ~= otherMatch then
                    compatible = false
                end
                local theirCharacter = other.Character
                local theirRoot = theirCharacter and theirCharacter:FindFirstChild("HumanoidRootPart")
                if myRoot and theirRoot and (myRoot.Position - theirRoot.Position).Magnitude > 1200 then
                    compatible = false
                end
            end
            if compatible then
                foundPatientZero = true
                break
            end
        end
    end
    local modeAttribute
    for _, name in ipairs(dmvsInfectionModeAttributes) do
        local value = player:GetAttribute(name)
        if typeof(value) == "string" and value ~= "" then
            modeAttribute = value:lower()
            break
        end
    end
    if not modeAttribute then
        for _, name in ipairs(dmvsInfectionModeAttributes) do
            local value = workspace:GetAttribute(name)
            if typeof(value) == "string" and value ~= "" then
                modeAttribute = value:lower()
                break
            end
        end
    end
    local active = not state.RoundEnded and
        (modeAttribute == "infection" or
            (not modeAttribute and (foundPatientZero or
                (state.Active and not dmvsTeamResolverState.InGame))))
    if not active then
        if modeAttribute and modeAttribute ~= "infection" and next(state.LateJoiners) ~= nil then
            table.clear(state.LateJoiners)
        end
        if state.Active or next(state.Targets) ~= nil then
            if modeAttribute and modeAttribute ~= "infection" then
                dmvsClearInfectionRound(false)
            else
                state.Active = false
                table.clear(state.Targets)
                table.clear(state.Inferred)
                table.clear(state.RoleTeams)
                if dmvsInvalidateRedirectSelection then dmvsInvalidateRedirectSelection() end
            end
        end
        return state
    end
    state.Active = true
    local teams = {}
    dmvsReadInfectionRoster(teams)
    state.RoleTeams = teams
    local infectedTeam
    local ambiguousTeam = false
    local markers = {}
    for _, other in ipairs(allPlayers) do
        local marker = dmvsInfectionAttribute(other)
        markers[other] = marker
        if marker == true or state.Converted[other] == true then
            local team = teams[other]
            if team then
                if infectedTeam and infectedTeam ~= team then ambiguousTeam = true end
                infectedTeam = team
            end
        end
    end
    local inferred = {}
    if infectedTeam and not ambiguousTeam then
        for other, team in pairs(teams) do
            if team == infectedTeam and markers[other] ~= false then
                inferred[other] = true
            end
        end
    end
    state.Inferred = inferred
    local function createTargets()
        local targets = {}
        for _, other in ipairs(allPlayers) do
            if markers[other] == true or state.Converted[other] == true
                or (markers[other] ~= false and inferred[other] == true) then
                targets[other] = true
            end
        end
        return targets
    end
    local targets = createTargets()
    local infectedRoots = {}
    for infectedPlayer in pairs(targets) do
        local infectedCharacter = infectedPlayer.Character
        local infectedRoot = infectedCharacter and infectedCharacter:FindFirstChild("HumanoidRootPart")
        if infectedRoot and infectedRoot:IsA("BasePart") then
            infectedRoots[#infectedRoots + 1] = infectedRoot
        end
    end
    for _, other in ipairs(allPlayers) do
        if other ~= player and state.LateJoiners[other] and markers[other] == nil
            and not targets[other] and other.Character then
            local rosterTeam = teams[other] or regularRoster[other.Name:lower()]
            local otherGame = other:GetAttribute("Game")
            local otherMatch = other:GetAttribute("MatchId")
            local sameGame = localGame ~= nil and localGame ~= "" and otherGame == localGame
            local sameMatch = matchId ~= nil and matchId ~= "" and otherMatch == matchId
            local differentGame = localGame ~= nil and localGame ~= "" and otherGame ~= nil
                and otherGame ~= "" and otherGame ~= localGame
            local differentMatch = matchId ~= nil and matchId ~= "" and otherMatch ~= nil
                and otherMatch ~= "" and otherMatch ~= matchId
            if not differentGame and not differentMatch then
                local sharesInfectedTeam = false
                for infectedPlayer in pairs(targets) do
                    local infectedRobloxTeam = infectedPlayer.Team
                    if infectedRobloxTeam and other.Team == infectedRobloxTeam
                        and (markers[infectedPlayer] == true or state.Converted[infectedPlayer] == true
                            or inferred[infectedPlayer] == true) then
                        sharesInfectedTeam = true
                        break
                    end
                end
                local nearInfected = false
                if not rosterTeam and not sameGame and not sameMatch and not sharesInfectedTeam then
                    local characterRoot = other.Character:FindFirstChild("HumanoidRootPart")
                    if characterRoot and characterRoot:IsA("BasePart") then
                        local position = characterRoot.Position
                        for _, infectedRoot in ipairs(infectedRoots) do
                            if (infectedRoot.Position - position).Magnitude <= 300 then
                                nearInfected = true
                                break
                            end
                        end
                    end
                end
                local participates = rosterTeam ~= nil or sameGame or sameMatch
                    or sharesInfectedTeam or nearInfected
                if participates and (not infectedTeam or ambiguousTeam or not rosterTeam or rosterTeam == infectedTeam) then
                    targets[other] = true
                end
            end
        end
    end
    local pending = state.Pending
    local changed = true
    while changed do
        changed = false
        for index = #pending, 1, -1 do
            local entry = pending[index]
            if now - entry.Time > 10 or entry.Killer.Parent ~= Players or entry.Victim.Parent ~= Players then
                table.remove(pending, index)
            elseif targets[entry.Killer] and not targets[entry.Victim]
                and (not state.ConvertedAt[entry.Killer]
                    or state.ConvertedAt[entry.Killer] <= entry.Time) then
                state.Converted[entry.Victim] = true
                state.ConvertedAt[entry.Victim] = entry.Time
                targets[entry.Victim] = true
                table.remove(pending, index)
                changed = true
            elseif targets[entry.Killer] then
                table.remove(pending, index)
            end
        end
    end
    local previous = state.Targets
    local targetChanged = false
    for other in pairs(previous) do
        if not targets[other] then targetChanged = true; break end
    end
    if not targetChanged then
        for other in pairs(targets) do
            if not previous[other] then targetChanged = true; break end
        end
    end
    state.Targets = targets
    if targetChanged and dmvsInvalidateRedirectSelection then
        dmvsInvalidateRedirectSelection()
    end
    return state
end

dmvsIsInfectionMode = function()
    return dmvsRefreshInfectionState(false).Active
end

local function dmvsIsInfectedTarget(targetPlayer)
    if not targetPlayer then return false end
    local state = dmvsRefreshInfectionState(false)
    return state.Active and state.Targets[targetPlayer] == true
end

local function dmvsInfectionMatchAllowed(targetPlayer, allowMissingCharacter)
    if not targetPlayer or targetPlayer == player or not targetPlayer.Parent
        or (not allowMissingCharacter and not targetPlayer.Character) then
        return false
    end
    local myGame = player:GetAttribute("Game")
    local targetGame = targetPlayer:GetAttribute("Game")
    if myGame ~= nil and myGame ~= "" and targetGame ~= nil and targetGame ~= "" and myGame ~= targetGame then
        return false
    end
    if (myGame == nil or myGame == "") and targetGame ~= nil and targetGame ~= "" then
        return false
    end
    local myMatch = player:GetAttribute("MatchId")
    local targetMatch = targetPlayer:GetAttribute("MatchId")
    if myMatch ~= nil and myMatch ~= "" and targetMatch ~= nil and targetMatch ~= "" and myMatch ~= targetMatch then
        return false
    end
    local myRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    local otherRoot = targetPlayer.Character and targetPlayer.Character:FindFirstChild("HumanoidRootPart")
    if myRoot and otherRoot and (myRoot.Position - otherRoot.Position).Magnitude > 1200 then
        return false
    end
    return true
end

local function dmvsInfectionMarkDirty()
    dmvsInfectionState.LastRefresh = -math.huge
end

local function dmvsInfectionOnKill(killer, victim)
    if typeof(killer) ~= "Instance" or not killer:IsA("Player")
        or typeof(victim) ~= "Instance" or not victim:IsA("Player")
        or killer == victim or not dmvsIsInfectionMode()
        or (killer ~= player and not dmvsInfectionMatchAllowed(killer, true))
        or (victim ~= player and not dmvsInfectionMatchAllowed(victim, true)) then
        return
    end
    local state = dmvsRefreshInfectionState(false)
    if state.Targets[victim] then return end
    if state.Targets[killer] then
        state.Converted[victim] = true
        state.ConvertedAt[victim] = os.clock()
        state.LastRefresh = -math.huge
        dmvsRefreshInfectionState(true)
    else
        if #state.Pending >= 96 then table.remove(state.Pending, 1) end
        state.Pending[#state.Pending + 1] = {Killer = killer, Victim = victim, Time = os.clock()}
        state.LastRefresh = -math.huge
    end
end

local dmvsIsInSameGame
dmvsIsInSameGame = function(targetPlayer)
    if not targetPlayer or targetPlayer == player or not targetPlayer.Parent then
        return false
    end

    if dmvsIsInfectionMode() then
        return dmvsInfectionMatchAllowed(targetPlayer) and dmvsIsInfectedTarget(targetPlayer)
    end

    local roster = dmvsRefreshScoreboardTeams(false)
    if not dmvsTeamResolverState.InGame or not roster[string.lower(targetPlayer.Name)] then
        return false
    end

    local myGame = player:GetAttribute("Game")
    local targetGame = targetPlayer:GetAttribute("Game")
    if myGame ~= nil and myGame ~= "" and targetGame ~= nil and targetGame ~= "" then
        if myGame ~= targetGame then return false end
    elseif (myGame == nil or myGame == "") and targetGame ~= nil and targetGame ~= "" then
        return false
    end

    local myMatch = player:GetAttribute("MatchId")
    local targetMatch = targetPlayer:GetAttribute("MatchId")
    if myMatch ~= nil and myMatch ~= "" and targetMatch ~= nil and targetMatch ~= "" and myMatch ~= targetMatch then
        return false
    end

    return true
end

local function dmvsResolvePlayerTeam(targetPlayer)
    if not targetPlayer then return nil end

    local snapshot = dmvsRefreshScoreboardTeams(false)
    local byName = snapshot[string.lower(targetPlayer.Name)]

    if not byName and targetPlayer.DisplayName then
        byName = snapshot[string.lower(targetPlayer.DisplayName)]
    end

    if byName then
        return byName
    end

    local attr = targetPlayer:GetAttribute("Team") or targetPlayer:GetAttribute("team")
    if attr ~= nil and tostring(attr) ~= "" then
        return tostring(attr)
    end

    if targetPlayer.Team then
        return targetPlayer.Team.Name
    end

    local teamColor = targetPlayer.TeamColor
    if teamColor and teamColor.Name ~= "White" and teamColor.Name ~= "Medium stone grey" then
        return "Color:" .. teamColor.Name
    end

    return nil
end

local function dmvsPlayersAreEnemies(firstPlayer, secondPlayer)
    if not firstPlayer or not secondPlayer or firstPlayer == secondPlayer then
        return false
    end
    if dmvsIsInfectionMode() then
        return dmvsIsInfectedTarget(secondPlayer)
    end

    local firstTeam = dmvsResolvePlayerTeam(firstPlayer)
    local secondTeam = dmvsResolvePlayerTeam(secondPlayer)

    if firstTeam ~= nil and secondTeam ~= nil then
        return firstTeam ~= secondTeam
    end

    return true
end

local function updateMyTeam()
    dmvsInvalidateScoreboard()
    if dmvsInvalidateRedirectSelection then dmvsInvalidateRedirectSelection() end
end

local function updateEnemy()
    dmvsInvalidateScoreboard()
    dmvsInfectionMarkDirty()
    if dmvsInvalidateRedirectSelection then dmvsInvalidateRedirectSelection() end
end

local dmvsTeamPlayerConnections = {}
local dmvsInfectionCharacterConnections = {}

local function disconnectPlayerTeamEvents(p)
    dmvsDisconnectConnectionList(dmvsInfectionCharacterConnections[p])
    dmvsInfectionCharacterConnections[p] = nil
    local connections = dmvsTeamPlayerConnections[p]
    if connections then
        dmvsDisconnectConnectionList(connections)
        dmvsTeamPlayerConnections[p] = nil
    end
end

local function dmvsWatchInfectionCharacter(p, character)
    dmvsDisconnectConnectionList(dmvsInfectionCharacterConnections[p])
    dmvsInfectionCharacterConnections[p] = nil
    if not character then return end
    local connections = {}
    dmvsInfectionCharacterConnections[p] = connections
    local function changed(name)
        if name == "InfectionPatientZero" or name == "InfectionInfected"
            or name == "IsInfected" or name == "Infected"
            or name == "IsZombie" or name == "Zombie" then
            dmvsInfectionMarkDirty()
            updateEnemy()
        end
    end
    connections[#connections + 1] = character.AttributeChanged:Connect(changed)
    local function bindHumanoid(humanoid)
        if humanoid and humanoid:IsA("Humanoid") then
            connections[#connections + 1] = humanoid.AttributeChanged:Connect(changed)
        end
    end
    bindHumanoid(character:FindFirstChildOfClass("Humanoid"))
    connections[#connections + 1] = character.ChildAdded:Connect(function(child)
        if child:IsA("Humanoid") then
            bindHumanoid(child)
            dmvsInfectionMarkDirty()
        end
    end)
end

local function setupPlayerEvents(p)
    if not p or p == player or not p.Parent then return end
    disconnectPlayerTeamEvents(p)
    dmvsTeamPlayerConnections[p] = {
        p:GetPropertyChangedSignal("Team"):Connect(updateEnemy),
        p:GetPropertyChangedSignal("TeamColor"):Connect(updateEnemy),
        p:GetAttributeChangedSignal("Team"):Connect(updateEnemy),
        p:GetAttributeChangedSignal("team"):Connect(updateEnemy),
        p:GetAttributeChangedSignal("Game"):Connect(updateEnemy),
        p:GetAttributeChangedSignal("MatchId"):Connect(updateEnemy),
        p.AttributeChanged:Connect(function(name)
            if name == "InfectionPatientZero" or name == "InfectionInfected"
                or name == "IsInfected" or name == "Infected"
                or name == "IsZombie" or name == "Zombie" then
                dmvsInfectionMarkDirty()
                updateEnemy()
            end
        end),
        p.CharacterAdded:Connect(function(character)
            dmvsWatchInfectionCharacter(p, character)
            dmvsInfectionMarkDirty()
            updateEnemy()
        end),
        p.CharacterRemoving:Connect(function(character)
            dmvsWatchInfectionCharacter(p, nil)
            dmvsInfectionMarkDirty()
            if dmvsClearTargetParts then dmvsClearTargetParts(character) end
        end)
    }
    dmvsWatchInfectionCharacter(p, p.Character)
    updateEnemy()
end

local nexvyrTargetConnections = {}
local nexvyrTargetMonitorActive = false
local nexvyrTargetMonitorSession = 0
local function nexvyrMonitorConnection(connection)
    nexvyrTargetConnections[#nexvyrTargetConnections + 1] = connection
    return connection
end
local function nexvyrStartTargetMonitor()
    if nexvyrTargetMonitorActive then return end
    nexvyrTargetMonitorActive = true
    nexvyrTargetMonitorSession += 1
    local session = nexvyrTargetMonitorSession
    local function localChanged() updateMyTeam(); dmvsInfectionMarkDirty() end
    for _, name in ipairs({"Team", "TeamColor"}) do
        nexvyrMonitorConnection(player:GetPropertyChangedSignal(name):Connect(localChanged))
    end
    for _, name in ipairs({"Team", "team", "Game", "MatchId", "GameMode", "MatchMode", "Mode"}) do
        nexvyrMonitorConnection(player:GetAttributeChangedSignal(name):Connect(localChanged))
    end
    nexvyrMonitorConnection(player.AttributeChanged:Connect(function(name)
        if name == "InfectionPatientZero" or name == "InfectionInfected" or name == "IsInfected"
            or name == "Infected" or name == "IsZombie" or name == "Zombie" then dmvsInfectionMarkDirty() end
    end))
    nexvyrMonitorConnection(player.CharacterAdded:Connect(dmvsInfectionMarkDirty))
    nexvyrMonitorConnection(playerGui.DescendantAdded:Connect(function(instance)
        if instance.Name == "IngameScore" or instance.Name == "TeamRed" or instance.Name == "TeamBlue" then
            dmvsInvalidateScoreboard(); dmvsInfectionMarkDirty()
        end
    end))
    nexvyrMonitorConnection(playerGui.DescendantRemoving:Connect(function(instance)
        if instance == dmvsTeamResolverState.Scoreboard or instance.Name == "IngameScore"
            or instance.Name == "TeamRed" or instance.Name == "TeamBlue" then
            dmvsInvalidateScoreboard(); dmvsInfectionMarkDirty()
        end
    end))
    for _, other in ipairs(Players:GetPlayers()) do
        if other ~= player then setupPlayerEvents(other) end
    end
    nexvyrMonitorConnection(Players.PlayerAdded:Connect(function(other)
        dmvsInfectionState.LateJoiners[other] = true
        setupPlayerEvents(other)
        dmvsInfectionMarkDirty()
    end))
    nexvyrMonitorConnection(Players.PlayerRemoving:Connect(function(other)
        disconnectPlayerTeamEvents(other)
        for i = #dmvsInfectionState.Pending, 1, -1 do
            local entry = dmvsInfectionState.Pending[i]
            if entry.Killer == other or entry.Victim == other then table.remove(dmvsInfectionState.Pending, i) end
        end
        for _, bucket in ipairs({"Converted", "ConvertedAt", "LateJoiners", "Inferred", "Targets", "RoleTeams"}) do
            dmvsInfectionState[bucket][other] = nil
        end
        updateEnemy()
    end))
    dmvsInvalidateScoreboard()
    dmvsInfectionMarkDirty()
    task.spawn(function()
        local registered = {}
        local listeners = {
            ["RE/Combat/Killed"] = dmvsInfectionOnKill,
            ["RE/Match/PlayerRespawned"] = dmvsInfectionMarkDirty,
            ["RE/Match/StartRoundGui"] = function() dmvsClearInfectionRound(false) end,
            ["RE/Match/MatchResults"] = function()
                if dmvsInfectionState.Active then dmvsClearInfectionRound(true) end
            end
        }
        while nexvyrTargetMonitorActive and session == nexvyrTargetMonitorSession do
            local packages = ReplicatedStorage:FindFirstChild("Packages")
            local networking = packages and packages:FindFirstChild("Networking")
            local finished = true
            for name, callback in pairs(listeners) do
                if not registered[name] then
                    local remote = networking and networking:FindFirstChild(name)
                    if remote and remote:IsA("RemoteEvent") then
                        nexvyrMonitorConnection(remote.OnClientEvent:Connect(callback))
                        registered[name] = true
                    else
                        finished = false
                    end
                end
            end
            if finished then break end
            task.wait(2)
        end
    end)
end
local function nexvyrStopTargetMonitor()
    if not nexvyrTargetMonitorActive then return end
    nexvyrTargetMonitorActive = false
    nexvyrTargetMonitorSession += 1
    dmvsDisconnectConnectionList(nexvyrTargetConnections)
    for other in pairs(dmvsTeamPlayerConnections) do disconnectPlayerTeamEvents(other) end
    dmvsDisconnectConnectionList(dmvsTeamResolverState.WatchConnections)
    dmvsTeamResolverState.Scoreboard = nil
    dmvsTeamResolverState.Snapshot = {}
    dmvsTeamResolverState.InGame = false
    dmvsTeamResolverState.Dirty = true
    dmvsClearInfectionRound(false)
end
startTargetMonitor = nexvyrStartTargetMonitor
stopTargetMonitor = nexvyrStopTargetMonitor

isEnemy = function(targetPlayer)
    if not dmvsIsInSameGame(targetPlayer) or not targetPlayer.Character then return false end
    if not dmvsIsTargetAlive(targetPlayer) then return false end
    return dmvsPlayersAreEnemies(player, targetPlayer)
end
local SAFE_ZONES = {
    {Center = Vector3.new(-320.50, 280.82, 16.00), Radius = 500},
    {Center = Vector3.new(1564.14, -155.45, 40.04), Radius = 300}
}
estaEnLobby = function()
    local character = player.Character
    if not character then return true end
    if character:FindFirstChildOfClass("ForceField") then return true end
    if player.Team then
        local name = player.Team.Name:lower()
        if name:find("lobby") or name:find("spectat") or name:find("espectador")
            or name:find("menu") or name:find("dead") then return true end
    end
    local root = character:FindFirstChild("HumanoidRootPart")
    if root then
        for _, zone in ipairs(SAFE_ZONES) do
            if (root.Position - zone.Center).Magnitude <= zone.Radius then return true end
        end
    end
    return false
end
IsInMatchStrict = function()
    if estaEnLobby() then return false end
    dmvsRefreshScoreboardTeams(false)
    return dmvsTeamResolverState.InGame or dmvsIsInfectionMode()
end
esEnemigoValido = function(other)
    if not isEnemy(other) then return false end
    local character = other.Character
    return character ~= nil and not character:FindFirstChildOfClass("ForceField")
        and dmvsIsTargetAlive(other)
end
esCuchillo = function(tool)
    if not tool or not tool:IsA("Tool") then return false end
    if tool:FindFirstChild("Slash") or tool:FindFirstChild("SlashStart") then return true end
    local name = tool.Name:lower()
    return name:find("knife", 1, true) ~= nil or name:find("cuchillo", 1, true) ~= nil
        or name:find("dagger", 1, true) ~= nil
end
esPistola = function(tool)
    if not tool or not tool:IsA("Tool") then return false end
    local beam = tool:FindFirstChild("showBeam")
    return beam ~= nil and beam:IsA("RemoteEvent")
end
obtenerPistola = function()
    local character = player.Character
    if character then
        for _, tool in ipairs(character:GetChildren()) do
            if esPistola(tool) then return tool end
        end
    end
    local backpack = player:FindFirstChildOfClass("Backpack")
    if backpack then
        for _, tool in ipairs(backpack:GetChildren()) do
            if esPistola(tool) then return tool end
        end
    end
    return nil
end
end



-- ------------- Auto Farm Evento (Halloween) -------------
getgenv().RoxHubAutoEventFarm = false

task.spawn(function()
    local Networking, RemoteFarm
    while task.wait(0.05) do
        if not getgenv().RoxHubAutoEventFarm then continue end
        pcall(function()
            if not RemoteFarm then
                Networking = ReplicatedStorage:FindFirstChild("Packages")
                Networking = Networking and Networking:FindFirstChild("Networking")
                RemoteFarm = Networking and Networking:FindFirstChild("RE/Events/CollectEventSpawnable")
            end
            if RemoteFarm then RemoteFarm:FireServer() end
        end)
        local char = player.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if hrp then
            local container = workspace:FindFirstChild("SpawnablesClient")
            if container then
                for _, obj in ipairs(container:GetChildren()) do
                    if not getgenv().RoxHubAutoEventFarm then break end
                    local touchPart = obj:FindFirstChild("Touch")
                    if touchPart then
                        pcall(function()
                            firetouchinterest(hrp, touchPart, 0)
                            firetouchinterest(hrp, touchPart, 1)
                        end)
                    end
                end
            end
        end
    end
end)

-- ------------- Kill All -------------
local KILLALL_MOVE_SPEED               = 39.9
local KILLALL_APPROACH_DISTANCE        = 2.5
local KILLALL_APPROACH_TOLERANCE       = 0.35
local KILLALL_SWING_INTERVAL           = 0.5
local KILLALL_SAFE_GROUND_THRESHOLD    = 3
local KILLALL_STICK_MAX_TIME           = 2.5
local KILLALL_STICK_MAX_DISTANCE       = 20
local KILLALL_VOID_PROTECTION          = 15
local KILLALL_HEALTH_STALL_TIME        = 1.5
local KILLALL_TARGET_GRACE_TIME        = 1.2
local KILLALL_PITCH_DEGREES            = 90
local KILLALL_HEIGHT_OFFSET            = 1.9
local KILLALL_HIDE_DEPTH               = 4
local KILLALL_HIDE_DURATION            = 0.5
local KILLALL_KNIFE_RANGE_Y            = 4.5
local KILLALL_PREDICTION_TIME          = 0.08
local KILLALL_JITTER_AMPLITUDE         = 0.8
local KILLALL_JITTER_SWITCH_MIN        = 0.05
local KILLALL_JITTER_SWITCH_MAX        = 0.12
local KILLALL_JITTER_LERP_SPEED        = 25
local KILLALL_UNDERGROUND_DEPTH        = 5
local KILLALL_UNDERGROUND_TOLERANCE    = 1.5
local KILLALL_TRIGGER_RADIUS           = 6.0
local KILLALL_VALIDATION_TOLERANCE     = 1.0
local KILLALL_VALIDATION_FRAMES        = 3

local RoxConnectionManager = {}
RoxConnectionManager.__index = RoxConnectionManager
function RoxConnectionManager.new() return setmetatable({ Items = {} }, RoxConnectionManager) end
function RoxConnectionManager:Add(task) self.Items[#self.Items + 1] = task; return task end
function RoxConnectionManager:Cleanup()
    for i = #self.Items, 1, -1 do
        local item = self.Items[i]
        self.Items[i] = nil
        local t = typeof(item)
        if t == "RBXScriptConnection" then pcall(function() item:Disconnect() end)
        elseif t == "Instance" then pcall(function() item:Destroy() end)
        elseif t == "function" then pcall(item) end
    end
end

local RoxKillAll = {}
RoxKillAll.__index = RoxKillAll

function RoxKillAll.new()
    return setmetatable({
        running = false,
        connections = RoxConnectionManager.new(),
        savedCollisions = {},
        swingAccumulator = 0,
        safePosition = nil,
        sticking = false,
        stickingStartTime = 0,
        lastEnemyHealth = nil,
        lastHealthChangeTime = 0,
        lastTargetSeenTime = 0,
        currentTarget = nil,
        lockedTargetPlayer = nil,
        lastStickTarget = nil,
        lastStickTargetHum = nil,
        hiding = false,
        hidingUntil = 0,
        targetFloor = nil,
        targetFloorY = nil,
        lastFloorTarget = nil,
        inKnifeRangeNow = false,
        forceDescent = false,
        jitterSide = 1,
        jitterCurrent = 0,
        jitterNextSwitch = 0,
        lastSetCFrame = nil,
        validFrames = 0,
        killActivated = false,
    }, RoxKillAll)
end

function RoxKillAll:DisableCollisions()
    local char = player.Character
    if not char then return end
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") and part.CanCollide then
            if self.savedCollisions[part] == nil then
                self.savedCollisions[part] = part.CanCollide
            end
            part.CanCollide = false
        end
    end
end

function RoxKillAll:RestoreCollisions()
    for part, value in pairs(self.savedCollisions) do
        if part.Parent then
            pcall(function() part.CanCollide = value end)
        end
    end
    table.clear(self.savedCollisions)
end

function RoxKillAll:GetRoot(p)
    local char = p and p.Character
    if not char then return nil end
    local root = char:FindFirstChild("HumanoidRootPart")
    if root and root:IsA("BasePart") then return root end
    return nil
end

function RoxKillAll:GetHumanoid(p)
    local char = p and p.Character
    return char and char:FindFirstChildOfClass("Humanoid") or nil
end

function RoxKillAll:GetFloorY(targetRoot)
    local hum = targetRoot.Parent and targetRoot.Parent:FindFirstChildOfClass("Humanoid")
    local hip = hum and tonumber(hum.HipHeight) or 2
    return targetRoot.Position.Y - hip - targetRoot.Size.Y / 2
end

function RoxKillAll:GetPlatformFloorY(targetRoot)
    if not targetRoot then return nil end
    if self.lastFloorTarget == targetRoot and self.targetFloorY then
        return self.targetFloorY
    end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { player.Character, targetRoot.Parent }
    local origin = targetRoot.Position + Vector3.new(0, 3, 0)
    local result = workspace:Raycast(origin, Vector3.new(0, -500, 0), params)
    if result then
        self.targetFloorY = result.Position.Y
        self.lastFloorTarget = targetRoot
        return self.targetFloorY
    end
    self.targetFloorY = self:GetFloorY(targetRoot)
    self.lastFloorTarget = targetRoot
    return self.targetFloorY
end

function RoxKillAll:IsInKnifeRange(myRoot, targetRoot)
    if not myRoot or not targetRoot then return false end
    local delta = targetRoot.Position - myRoot.Position
    local horizontal = Vector3.new(delta.X, 0, delta.Z).Magnitude
    local vertical = math.abs(delta.Y)
    return horizontal <= (KILLALL_APPROACH_DISTANCE + KILLALL_APPROACH_TOLERANCE) and vertical <= KILLALL_KNIFE_RANGE_Y
end

function RoxKillAll:IsLockedTargetValid()
    local lp = self.lockedTargetPlayer
    if not lp then return false end
    if not lp.Parent then return false end
    if not esEnemigoValido(lp) then return false end
    local char = lp.Character
    if not char then return false end
    local root = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not root or not hum then return false end
    if hum.Health <= 0 then return false end
    return root
end

function RoxKillAll:GetClosestEnemy()
    local myRoot = self:GetRoot(player)
    if not myRoot then return nil end
    local lockedRoot = self:IsLockedTargetValid()
    if lockedRoot then return lockedRoot end
    self.lockedTargetPlayer = nil
    self.currentTarget = nil
    local best, bestDist, bestPlayer = nil, nil, nil
    for _, other in ipairs(Players:GetPlayers()) do
        if other ~= player and esEnemigoValido(other) then
            local hum = self:GetHumanoid(other)
            local root = self:GetRoot(other)
            if root and hum and hum.Health > 0 then
                local dist = (root.Position - myRoot.Position).Magnitude
                if not bestDist or dist < bestDist then
                    best, bestDist, bestPlayer = root, dist, other
                end
            end
        end
    end
    if bestPlayer then self.lockedTargetPlayer = bestPlayer end
    return best
end

function RoxKillAll:IsInMatch() return IsInMatchStrict() end

function RoxKillAll:ResetState()
    self.sticking = false
    self.stickingStartTime = 0
    self.lastEnemyHealth = nil
    self.lastHealthChangeTime = 0
    self.targetFloor = nil
    self.inKnifeRangeNow = false
    self.forceDescent = false
    self.jitterSide = 1
    self.jitterCurrent = 0
    self.jitterNextSwitch = 0
    self.lastSetCFrame = nil
    self.validFrames = 0
    self.killActivated = false
    self:RestoreCollisions()
    local hum = self:GetHumanoid(player)
    if hum and hum.PlatformStand then pcall(function() hum.PlatformStand = false end) end
end

function RoxKillAll:ReturnToSafePosition(myRoot)
    if not self.safePosition or not myRoot then return end
    if myRoot.Position.Y < (self.safePosition.Y - KILLALL_SAFE_GROUND_THRESHOLD) then
        pcall(function()
            myRoot.CFrame = CFrame.new(self.safePosition)
            myRoot.AssemblyLinearVelocity  = Vector3.zero
            myRoot.AssemblyAngularVelocity = Vector3.zero
        end)
    end
end

function RoxKillAll:ForceReturnToSafe(myRoot)
    if not self.safePosition or not myRoot then return end
    pcall(function()
        myRoot.CFrame = CFrame.new(self.safePosition)
        myRoot.AssemblyLinearVelocity  = Vector3.zero
        myRoot.AssemblyAngularVelocity = Vector3.zero
    end)
end

function RoxKillAll:IsFallingIntoVoid(myRoot)
    if not self.safePosition or not myRoot then return false end
    return myRoot.Position.Y < (self.safePosition.Y - KILLALL_VOID_PROTECTION)
end

function RoxKillAll:HideBelowMap()
    local myRoot = self:GetRoot(player)
    if not myRoot then return end
    local baseY = self.safePosition and self.safePosition.Y or myRoot.Position.Y
    local hideY = baseY - KILLALL_HIDE_DEPTH
    local x, z = myRoot.Position.X, myRoot.Position.Z
    pcall(function()
        myRoot.CFrame = CFrame.new(x, hideY, z)
        myRoot.AssemblyLinearVelocity  = Vector3.zero
        myRoot.AssemblyAngularVelocity = Vector3.zero
    end)
    self.hiding = true
    self.hidingUntil = os.clock() + KILLALL_HIDE_DURATION
end

function RoxKillAll:IsKnife(tool)
    if not (tool and tool:IsA("Tool")) then return false end
    if tool:FindFirstChild("fire") or tool:FindFirstChild("showBeam") then return false end
    return tool:FindFirstChild("Slash") ~= nil or tool:FindFirstChild("SlashStart") ~= nil
end

function RoxKillAll:FindKnife()
    local char = player.Character
    if char then
        for _, child in ipairs(char:GetChildren()) do
            if self:IsKnife(child) then return child, true end
        end
    end
    local backpack = player:FindFirstChildOfClass("Backpack")
    if backpack then
        for _, child in ipairs(backpack:GetChildren()) do
            if self:IsKnife(child) then return child, false end
        end
    end
    return nil, false
end

function RoxKillAll:SwingKnife(dt)
    self.swingAccumulator = self.swingAccumulator + dt
    if self.swingAccumulator < KILLALL_SWING_INTERVAL then return end
    self.swingAccumulator = 0
    local tool, equipped = self:FindKnife()
    if not tool then return end
    if not equipped then
        local hum = self:GetHumanoid(player)
        if not hum then return end
        pcall(function() hum:EquipTool(tool) end)
        if tool.Parent ~= player.Character then return end
    end
    pcall(function() tool:Activate() end)
end

function RoxKillAll:UpdateJitter(dt)
    local now = os.clock()
    if now >= self.jitterNextSwitch then
        self.jitterSide = (math.random() < 0.5) and 1 or -1
        self.jitterNextSwitch = now + KILLALL_JITTER_SWITCH_MIN + math.random() * (KILLALL_JITTER_SWITCH_MAX - KILLALL_JITTER_SWITCH_MIN)
    end
    local targetOffset = self.jitterSide * KILLALL_JITTER_AMPLITUDE
    self.jitterCurrent = self.jitterCurrent + (targetOffset - self.jitterCurrent) * math.clamp(dt * KILLALL_JITTER_LERP_SPEED, 0, 1)
end

function RoxKillAll:CheckServerValidation(myRoot)
    if self.killActivated then return true end
    if not self.lastSetCFrame then return false end
    local diff = (myRoot.Position - self.lastSetCFrame.Position).Magnitude
    if diff <= KILLALL_VALIDATION_TOLERANCE then
        self.validFrames = self.validFrames + 1
        if self.validFrames >= KILLALL_VALIDATION_FRAMES then
            self.killActivated = true
            self.swingAccumulator = KILLALL_SWING_INTERVAL
            return true
        end
    else
        self.validFrames = 0
    end
    return false
end

function RoxKillAll:ForceUnderground(myRoot, targetRoot)
    if not myRoot or not targetRoot then return end
    local floorY = self:GetPlatformFloorY(targetRoot)
    if not floorY then return end
    local targetY = floorY - KILLALL_UNDERGROUND_DEPTH
    if myRoot.Position.Y > targetY + KILLALL_UNDERGROUND_TOLERANCE then
        pcall(function()
            myRoot.CFrame = CFrame.new(myRoot.Position.X, targetY, myRoot.Position.Z)
            myRoot.AssemblyLinearVelocity  = Vector3.zero
            myRoot.AssemblyAngularVelocity = Vector3.zero
        end)
    end
end

function RoxKillAll:ApproachTarget(myRoot, targetRoot, dt)
    dt = dt or 0
    local myPos = myRoot.Position
    local targetPos = targetRoot.Position
    local deltaXZ = Vector3.new(targetPos.X - myPos.X, 0, targetPos.Z - myPos.Z)
    local hDist = deltaXZ.Magnitude

    if hDist <= KILLALL_TRIGGER_RADIUS then
        if not self.sticking then
            local lookTarget = Vector3.new(targetPos.X, myPos.Y, targetPos.Z)
            local targetCF = CFrame.lookAt(myPos, lookTarget)
            self.lastSetCFrame = targetCF
            pcall(function()
                myRoot.CFrame = targetCF
                myRoot.AssemblyLinearVelocity = Vector3.zero
                myRoot.AssemblyAngularVelocity = Vector3.zero
            end)
            if self:CheckServerValidation(myRoot) then
                self.sticking = true
                self.stickingStartTime = os.clock()
                self.lastStickTarget = targetRoot
                self.targetFloor = nil
                self.forceDescent = true
                local hum = self:GetHumanoid(targetRoot.Parent)
                self.lastEnemyHealth = hum and hum.Health or nil
                self.lastHealthChangeTime = os.clock()
                self.lastStickTargetHum = hum
                self.jitterCurrent = 0
            end
        end
        return
    end

    self.lastSetCFrame = nil
    self.validFrames = 0
    local dir = deltaXZ.Unit
    local perp = Vector3.new(-dir.Z, 0, dir.X)
    self:UpdateJitter(dt)
    local step = KILLALL_MOVE_SPEED * dt
    local travel = math.min(step, math.max(0, hDist - KILLALL_TRIGGER_RADIUS))
    local maxJitterByDistance = math.sqrt(math.max(0, travel * (2 * hDist - travel))) * 0.85
    local jitterFactor = math.clamp((hDist - KILLALL_TRIGGER_RADIUS) / 8, 0, 1)
    local desiredJitter = self.jitterCurrent * jitterFactor
    local actualJitter = math.clamp(desiredJitter, -maxJitterByDistance, maxJitterByDistance)

    local baseX = myPos.X + dir.X * travel
    local baseZ = myPos.Z + dir.Z * travel
    local newX = baseX + perp.X * actualJitter
    local newZ = baseZ + perp.Z * actualJitter

    local floorY = self:GetPlatformFloorY(targetRoot)
    local newY
    if floorY then newY = floorY - KILLALL_UNDERGROUND_DEPTH else newY = myPos.Y end

    local newPos = Vector3.new(newX, newY, newZ)
    local lookTarget = Vector3.new(targetPos.X, newPos.Y, targetPos.Z)
    local newCFrame = CFrame.lookAt(newPos, lookTarget)

    pcall(function()
        myRoot.CFrame = newCFrame
        myRoot.AssemblyLinearVelocity = Vector3.zero
        myRoot.AssemblyAngularVelocity = Vector3.zero
    end)
end

function RoxKillAll:CanStickToTarget(myRoot, targetRoot)
    if not targetRoot or not targetRoot.Parent then return false end
    local targetPlayer = Players:GetPlayerFromCharacter(targetRoot.Parent)
    if not targetPlayer or not esEnemigoValido(targetPlayer) then return false end
    local targetHum = targetRoot.Parent:FindFirstChildOfClass("Humanoid")
    if not targetHum or targetHum.Health <= 0 then return false end
    local distHorizontal = (Vector3.new(myRoot.Position.X, 0, myRoot.Position.Z) - Vector3.new(targetRoot.Position.X, 0, targetRoot.Position.Z)).Magnitude
    if distHorizontal > KILLALL_STICK_MAX_DISTANCE then return false end
    return true
end

function RoxKillAll:StickToTarget(myRoot, targetRoot)
    local targetPos = targetRoot.Position
    local targetHum = targetRoot.Parent and targetRoot.Parent:FindFirstChildOfClass("Humanoid")
    local onGround  = targetHum and targetHum.FloorMaterial ~= Enum.Material.Air
    if targetRoot ~= self.lastStickTarget then
        self.lastStickTarget = targetRoot
        self.targetFloor     = nil
    end
    if onGround or not self.targetFloor then
        self.targetFloor = self:GetFloorY(targetRoot)
    end
    local myPos = myRoot.Position
    local dir = Vector3.new(myPos.X - targetPos.X, 0, myPos.Z - targetPos.Z)
    if dir.Magnitude < 0.05 then dir = Vector3.new(0, 0, 1) else dir = dir.Unit end
    local x = targetPos.X + dir.X * KILLALL_APPROACH_DISTANCE
    local z = targetPos.Z + dir.Z * KILLALL_APPROACH_DISTANCE
    local inRange = self:IsInKnifeRange(myRoot, targetRoot)
    local y
    if inRange and not self.forceDescent then
        y = myPos.Y
    else
        y = self.targetFloor - KILLALL_HEIGHT_OFFSET
        if inRange then self.forceDescent = false end
    end
    pcall(function()
        myRoot.CFrame = CFrame.new(x, y, z) * CFrame.Angles(math.rad(KILLALL_PITCH_DEGREES), 0, 0)
        myRoot.AssemblyLinearVelocity  = Vector3.zero
        myRoot.AssemblyAngularVelocity = Vector3.zero
    end)
end

function RoxKillAll:CheckEnemyHealth(targetRoot)
    local targetHum = targetRoot.Parent and targetRoot.Parent:FindFirstChildOfClass("Humanoid")
    if not targetHum then return false end
    local currentHealth = targetHum.Health
    if self.lastEnemyHealth == nil then
        self.lastEnemyHealth = currentHealth
        self.lastHealthChangeTime = os.clock()
        return false
    end
    if currentHealth < self.lastEnemyHealth then
        self.lastEnemyHealth = currentHealth
        self.lastHealthChangeTime = os.clock()
        return false
    end
    if (os.clock() - self.lastHealthChangeTime) >= KILLALL_HEALTH_STALL_TIME then return true end
    return false
end

function RoxKillAll:Update(dt)
    if not self:IsInMatch() then
        self:ResetState()
        self.currentTarget = nil
        self.lockedTargetPlayer = nil
        self.lastStickTarget = nil
        self.lastFloorTarget = nil
        self.targetFloorY = nil
        return
    end
    local myRoot = self:GetRoot(player)
    if not myRoot then
        self:ResetState()
        self.currentTarget = nil
        self.lockedTargetPlayer = nil
        return
    end
    if self.lastStickTargetHum then
        local hum = self.lastStickTargetHum
        if not hum.Parent or hum.Health <= 0 then
            self:HideBelowMap()
            self.inKnifeRangeNow      = false
            self.forceDescent         = false
            self.lastStickTargetHum   = nil
            self.lastStickTarget      = nil
            self.sticking             = false
            self.stickingStartTime    = 0
            self.lastEnemyHealth      = nil
            self.lastHealthChangeTime = 0
            self.targetFloor          = nil
            self.killActivated        = false
            self.validFrames          = 0
            self.lastSetCFrame        = nil
            return
        end
    end
    if self.hiding then
        if os.clock() >= self.hidingUntil then
            self.hiding = false
        else
            pcall(function()
                myRoot.AssemblyLinearVelocity  = Vector3.zero
                myRoot.AssemblyAngularVelocity = Vector3.zero
            end)
            return
        end
    end
    if self:IsFallingIntoVoid(myRoot) then
        self:ForceReturnToSafe(myRoot)
        self:ResetState()
        self.currentTarget = nil
        self.lockedTargetPlayer = nil
        self.lastStickTarget = nil
        local hum = self:GetHumanoid(player)
        if hum then pcall(function() hum.PlatformStand = false end) end
        return
    end
    local target = self:GetClosestEnemy()
    if target then
        self.currentTarget      = target
        self.lastTargetSeenTime = os.clock()
    end
    if not target then
        local justLostTarget = (os.clock() - (self.lastTargetSeenTime or 0)) < KILLALL_TARGET_GRACE_TIME
        local isUnderground  = self.safePosition and myRoot.Position.Y < (self.safePosition.Y - 2)
        if justLostTarget and isUnderground then
            pcall(function()
                myRoot.AssemblyLinearVelocity  = Vector3.zero
                myRoot.AssemblyAngularVelocity = Vector3.zero
            end)
            return
        end
        self:ReturnToSafePosition(myRoot)
        self:ResetState()
        self.currentTarget = nil
        self.lockedTargetPlayer = nil
        self.lastStickTarget = nil
        self.lastFloorTarget = nil
        self.targetFloorY = nil
        if self.safePosition then
            local hum = self:GetHumanoid(player)
            if hum then pcall(function() hum.PlatformStand = false end) end
        end
        return
    end
    self:DisableCollisions()
    if self.lastStickTarget then
        local inRange = self:IsInKnifeRange(myRoot, self.lastStickTarget)
        if inRange and not self.inKnifeRangeNow then
            self.swingAccumulator = KILLALL_SWING_INTERVAL
            self.inKnifeRangeNow = true
        elseif not inRange then
            self.inKnifeRangeNow = false
        end
    end
    self:SwingKnife(dt or 0)
    local hum = self:GetHumanoid(player)
    if hum and not hum.PlatformStand then
        pcall(function() hum.PlatformStand = true end)
    end
    if self.safePosition and myRoot.Position.Y >= (self.safePosition.Y - KILLALL_SAFE_GROUND_THRESHOLD) then
        self.safePosition = Vector3.new(myRoot.Position.X, self.safePosition.Y, myRoot.Position.Z)
    end
    if not self.sticking then self:ForceUnderground(myRoot, target) end
    if self.sticking then
        local lostTarget  = (target ~= self.lastStickTarget)
        local timedOut    = (os.clock() - self.stickingStartTime) > KILLALL_STICK_MAX_TIME
        local cannotStick = not self:CanStickToTarget(myRoot, target)
        local cannotKill  = self:CheckEnemyHealth(target)
        if lostTarget or timedOut or cannotStick or cannotKill then
            self.sticking             = false
            self.stickingStartTime    = 0
            self.lastEnemyHealth      = nil
            self.lastHealthChangeTime = 0
            self.targetFloor          = nil
            self.inKnifeRangeNow      = false
            self.forceDescent         = false
            self.killActivated        = false
            self.validFrames          = 0
            self.lastSetCFrame        = nil
            if lostTarget then self.lastStickTarget = nil end
        else
            self:StickToTarget(myRoot, target)
            return
        end
    end
    self:ApproachTarget(myRoot, target, dt or 0)
end

function RoxKillAll:Start()
    if self.running then return end
    self.running = true
    self.swingAccumulator      = 0
    self.sticking              = false
    self.stickingStartTime     = 0
    self.lastEnemyHealth       = nil
    self.lastHealthChangeTime  = 0
    self.lastTargetSeenTime    = 0
    self.currentTarget         = nil
    self.lockedTargetPlayer    = nil
    self.lastStickTarget       = nil
    self.lastStickTargetHum    = nil
    self.hiding                = false
    self.hidingUntil           = 0
    self.targetFloor           = nil
    self.targetFloorY          = nil
    self.lastFloorTarget       = nil
    self.inKnifeRangeNow       = false
    self.forceDescent          = false
    self.jitterSide = 1
    self.jitterCurrent = 0
    self.jitterNextSwitch = 0
    self.lastSetCFrame = nil
    self.validFrames = 0
    self.killActivated = false

    local myRoot = self:GetRoot(player)
    if myRoot then
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = { player.Character }
        local origin = myRoot.Position + Vector3.new(0, 5, 0)
        local result = workspace:Raycast(origin, Vector3.new(0, -500, 0), params)
        if result then
            self.safePosition = Vector3.new(myRoot.Position.X, result.Position.Y + 3, myRoot.Position.Z)
        else
            self.safePosition = myRoot.Position
        end
    else
        self.safePosition = nil
    end

    self.connections:Add(RunService.Heartbeat:Connect(function(dt)
        if not self.running then return end
        self:Update(dt)
    end))

    self.connections:Add(player.CharacterAdded:Connect(function()
        table.clear(self.savedCollisions)
        self.sticking = false
        self.safePosition = nil
        self.stickingStartTime = 0
        self.lastEnemyHealth = nil
        self.lastHealthChangeTime = 0
        self.lastTargetSeenTime = 0
        self.currentTarget = nil
        self.lockedTargetPlayer = nil
        self.lastStickTarget = nil
        self.lastStickTargetHum = nil
        self.hiding = false
        self.hidingUntil = 0
        self.targetFloor = nil
        self.targetFloorY = nil
        self.lastFloorTarget = nil
        self.inKnifeRangeNow = false
        self.forceDescent = false
        self.jitterSide = 1
        self.jitterCurrent = 0
        self.jitterNextSwitch = 0
        self.lastSetCFrame = nil
        self.validFrames = 0
        self.killActivated = false
    end))
end

function RoxKillAll:Stop()
    if not self.running then return end
    local myRoot = self:GetRoot(player)
    if myRoot and self.safePosition then
        pcall(function()
            myRoot.CFrame = CFrame.new(self.safePosition)
            myRoot.AssemblyLinearVelocity  = Vector3.zero
            myRoot.AssemblyAngularVelocity = Vector3.zero
        end)
    end
    self.running = false
    self.connections:Cleanup()
    self.connections = RoxConnectionManager.new()
    self:ResetState()
    self.currentTarget = nil
    self.lockedTargetPlayer = nil
    self.lastStickTarget = nil
    self.lastStickTargetHum = nil
    self.hiding = false
    self.hidingUntil = 0
    self.inKnifeRangeNow = false
    self.forceDescent = false
    self.killActivated = false
    self.targetFloorY = nil
    self.lastFloorTarget = nil
end

local RoxKillAllInstance = RoxKillAll.new()


local function LoadHub()
	local ScreenGui = Instance.new("ScreenGui")
	ScreenGui.Name = "01ROXHUB"
	ScreenGui.ResetOnSpawn = false
	ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	ScreenGui.Parent = PlayerGui

	local C_BG          = Color3.fromRGB(18, 20, 28)
	local C_BG_TOP      = Color3.fromRGB(12, 14, 20)
	local C_SIDEBAR     = Color3.fromRGB(14, 16, 24)
	local C_CONTENT     = Color3.fromRGB(20, 22, 30)
	local C_BOX         = Color3.fromRGB(30, 33, 44)
	local C_BOX_2       = Color3.fromRGB(24, 27, 35)
	local C_TEXT        = Color3.fromRGB(255, 255, 255)
	local C_TEXT_DIM    = Color3.fromRGB(150, 158, 175)
	local C_ACCENT      = Color3.fromRGB(0, 140, 255)
	local C_ACCENT_SOFT = Color3.fromRGB(0, 100, 210)
	local C_DIVIDER     = Color3.fromRGB(45, 50, 65)
	local C_RED         = Color3.fromRGB(200, 45, 50)
	local C_RED_HOVER   = Color3.fromRGB(230, 60, 65)
	local C_GOLD        = Color3.fromRGB(235, 200, 90)
	local C_GREEN       = Color3.fromRGB(80, 210, 100)
	local C_GREEN_DARK  = Color3.fromRGB(22, 40, 28)
	local C_LINK        = Color3.fromRGB(120, 180, 255)
	local C_DISCORD     = Color3.fromRGB(88, 101, 242)
	local C_DISCORD_H   = Color3.fromRGB(110, 122, 255)
	local C_WHITE       = Color3.fromRGB(255, 255, 255)

	local DISCORD_URL = "https://discord.gg/mWBffStfJ"

	local MainButton = Instance.new("ImageButton")
	MainButton.Name = "MainButton"
	MainButton.Size = UDim2.new(0, 50, 0, 50)
	MainButton.Position = UDim2.new(0.5, -25, 0.5, -25)
	MainButton.BackgroundColor3 = C_BG_TOP
	MainButton.BorderSizePixel = 0
	MainButton.Image = "rbxassetid://76111147434526"
	MainButton.ScaleType = Enum.ScaleType.Fit
	MainButton.Active = true
	MainButton.Draggable = true
	MainButton.Parent = ScreenGui

	local MainBtnCorner = Instance.new("UICorner")
	MainBtnCorner.CornerRadius = UDim.new(0, 10)
	MainBtnCorner.Parent = MainButton

	local MainBtnPad = Instance.new("UIPadding")
	MainBtnPad.PaddingTop = UDim.new(0, 6)
	MainBtnPad.PaddingBottom = UDim.new(0, 6)
	MainBtnPad.PaddingLeft = UDim.new(0, 6)
	MainBtnPad.PaddingRight = UDim.new(0, 6)
	MainBtnPad.Parent = MainButton

	local MainBtnStroke = Instance.new("UIStroke")
	MainBtnStroke.Color = Color3.fromRGB(255, 255, 255)
	MainBtnStroke.Thickness = 1
	MainBtnStroke.Transparency = 0.3
	MainBtnStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	MainBtnStroke.Parent = MainButton

	local PulseRing = Instance.new("Frame")
	PulseRing.Size = UDim2.new(1, 0, 1, 0)
	PulseRing.Position = UDim2.new(0, 0, 0, 0)
	PulseRing.BackgroundTransparency = 1
	PulseRing.ZIndex = 0
	PulseRing.Parent = MainButton

	local PulseRingCorner = Instance.new("UICorner")
	PulseRingCorner.CornerRadius = UDim.new(0, 10)
	PulseRingCorner.Parent = PulseRing

	local PulseRingStroke = Instance.new("UIStroke")
	PulseRingStroke.Color = Color3.fromRGB(255, 255, 255)
	PulseRingStroke.Thickness = 2
	PulseRingStroke.Transparency = 0.2
	PulseRingStroke.Parent = PulseRing

	task.spawn(function()
		while MainButton.Parent do
			PulseRing.Size = UDim2.new(1, 0, 1, 0)
			PulseRing.Position = UDim2.new(0, 0, 0, 0)
			PulseRingStroke.Transparency = 0.2
			TweenService:Create(PulseRing, TweenInfo.new(1.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = UDim2.new(1, 40, 1, 40),
				Position = UDim2.new(0, -20, 0, -20)
			}):Play()
			TweenService:Create(PulseRingStroke, TweenInfo.new(1.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Transparency = 1, Thickness = 0
			}):Play()
			task.wait(1.6)
		end
	end)

	task.spawn(function()
		while MainButton.Parent do
			TweenService:Create(MainBtnStroke, TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
				Transparency = 0.05, Thickness = 2
			}):Play()
			task.wait(1.2)
			if not MainButton.Parent then break end
			TweenService:Create(MainBtnStroke, TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
				Transparency = 0.4, Thickness = 1
			}):Play()
			task.wait(1.2)
		end
	end)

	local MainFrame = Instance.new("Frame")
	MainFrame.Name = "MainFrame"
	MainFrame.Size = UDim2.new(0, 560, 0, 340)
	MainFrame.Position = UDim2.new(0.5, -280, 0.5, -170)
	MainFrame.BackgroundColor3 = C_BG
	MainFrame.BorderSizePixel = 0
	MainFrame.Visible = false
	MainFrame.Active = true
	MainFrame.Draggable = true
	MainFrame.ClipsDescendants = true
	MainFrame.Parent = ScreenGui

	local MainCorner = Instance.new("UICorner")
	MainCorner.CornerRadius = UDim.new(0, 12)
	MainCorner.Parent = MainFrame

	local MainStroke = Instance.new("UIStroke")
	MainStroke.Color = C_ACCENT
	MainStroke.Thickness = 1
	MainStroke.Transparency = 0.55
	MainStroke.Parent = MainFrame

	local MenuBgImage = Instance.new("ImageLabel")
	MenuBgImage.Name = "MenuBackground"
	MenuBgImage.Size = UDim2.new(1, 0, 1, 0)
	MenuBgImage.Position = UDim2.new(0, 0, 0, 0)
	MenuBgImage.BackgroundTransparency = 1
	MenuBgImage.Image = "rbxassetid://120887660443421"
	MenuBgImage.ScaleType = Enum.ScaleType.Crop
	MenuBgImage.ImageTransparency = 0.35
	MenuBgImage.ZIndex = 0
	MenuBgImage.Parent = MainFrame

	local MenuBgCorner = Instance.new("UICorner")
	MenuBgCorner.CornerRadius = UDim.new(0, 12)
	MenuBgCorner.Parent = MenuBgImage

	local MainShadow = Instance.new("ImageLabel")
	MainShadow.Size = UDim2.new(1, 40, 1, 40)
	MainShadow.Position = UDim2.new(0, -20, 0, -20)
	MainShadow.BackgroundTransparency = 1
	MainShadow.Image = "rbxassetid://5028857084"
	MainShadow.ImageColor3 = Color3.fromRGB(0, 0, 0)
	MainShadow.ImageTransparency = 0.4
	MainShadow.ScaleType = Enum.ScaleType.Slice
	MainShadow.SliceCenter = Rect.new(24, 24, 276, 276)
	MainShadow.ZIndex = 0
	MainShadow.Parent = MainFrame

	local ParticleHolder = Instance.new("Frame")
	ParticleHolder.Size = UDim2.new(1, 0, 1, 0)
	ParticleHolder.BackgroundTransparency = 1
	ParticleHolder.BorderSizePixel = 0
	ParticleHolder.ZIndex = 0
	ParticleHolder.ClipsDescendants = true
	ParticleHolder.Parent = MainFrame

	local function CreateParticle()
		local particle = Instance.new("Frame")
		local size = math.random(1, 2)
		particle.Size = UDim2.new(0, size, 0, size)
		particle.Position = UDim2.new(math.random(), 0, math.random(), 0)
		particle.BackgroundColor3 = C_ACCENT
		particle.BackgroundTransparency = math.random(50, 80) / 100
		particle.BorderSizePixel = 0
		particle.ZIndex = 0
		particle.Parent = ParticleHolder

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = particle

		task.spawn(function()
			local speed = math.random(15, 35) / 1000
			while particle.Parent do
				particle.Position = particle.Position + UDim2.new(0, 0, speed, 0)
				if particle.Position.Y.Scale > 1 then
					particle.Position = UDim2.new(math.random(), 0, -0.05, 0)
				end
				RunService.Heartbeat:Wait()
			end
		end)
	end

	for i = 1, 70 do CreateParticle() end

	local TopBar = Instance.new("Frame")
	TopBar.Size = UDim2.new(1, 0, 0, 42)
	TopBar.BackgroundColor3 = C_BG_TOP
	TopBar.BackgroundTransparency = 0.15
	TopBar.BorderSizePixel = 0
	TopBar.ZIndex = 2
	TopBar.Parent = MainFrame

	local TopCorner = Instance.new("UICorner")
	TopCorner.CornerRadius = UDim.new(0, 12)
	TopCorner.Parent = TopBar

	local TopFix = Instance.new("Frame")
	TopFix.Size = UDim2.new(1, 0, 0, 12)
	TopFix.Position = UDim2.new(0, 0, 1, -12)
	TopFix.BackgroundColor3 = C_BG_TOP
	TopFix.BackgroundTransparency = 0.15
	TopFix.BorderSizePixel = 0
	TopFix.ZIndex = 3
	TopFix.Parent = TopBar

	local TopAccent = Instance.new("Frame")
	TopAccent.Size = UDim2.new(1, 0, 0, 2)
	TopAccent.Position = UDim2.new(0, 0, 1, -2)
	TopAccent.BackgroundColor3 = C_ACCENT
	TopAccent.BorderSizePixel = 0
	TopAccent.ZIndex = 4
	TopAccent.Parent = TopBar

	local TopAccentGradient = Instance.new("UIGradient")
	TopAccentGradient.Transparency = NumberSequence.new{
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0),
		NumberSequenceKeypoint.new(1, 1)
	}
	TopAccentGradient.Parent = TopAccent

	local TopLogo = Instance.new("ImageLabel")
	TopLogo.Size = UDim2.new(0, 26, 0, 26)
	TopLogo.Position = UDim2.new(0, 14, 0, 8)
	TopLogo.BackgroundTransparency = 1
	TopLogo.Image = "rbxassetid://76111147434526"
	TopLogo.ScaleType = Enum.ScaleType.Fit
	TopLogo.ZIndex = 5
	TopLogo.Parent = TopBar

	local TopLogoCorner = Instance.new("UICorner")
	TopLogoCorner.CornerRadius = UDim.new(0, 6)
	TopLogoCorner.Parent = TopLogo

	local Title = Instance.new("TextLabel")
	Title.Size = UDim2.new(1, -120, 1, 0)
	Title.Position = UDim2.new(0, 48, 0, 0)
	Title.BackgroundTransparency = 1
	Title.Text = "MYSTERY VS SHERIFFS DUELOS"
	Title.TextColor3 = C_TEXT
	Title.TextSize = 13
	Title.Font = Enum.Font.GothamBold
	Title.TextXAlignment = Enum.TextXAlignment.Left
	Title.ZIndex = 5
	Title.Parent = TopBar

	local TitleAccent = Instance.new("TextLabel")
	TitleAccent.Size = UDim2.new(0, 90, 1, 0)
	TitleAccent.Position = UDim2.new(0, 232, 0, 0)
	TitleAccent.BackgroundTransparency = 1
	TitleAccent.Text = "   • FREE BETA BY 01ROXHUB"
	TitleAccent.TextColor3 = C_ACCENT
	TitleAccent.TextSize = 12
	TitleAccent.Font = Enum.Font.GothamBold
	TitleAccent.TextXAlignment = Enum.TextXAlignment.Left
	TitleAccent.ZIndex = 5
	TitleAccent.Parent = TopBar

	local BtnSize = 28
	local CloseBtn = Instance.new("TextButton")
	CloseBtn.Size = UDim2.new(0, BtnSize, 0, BtnSize)
	CloseBtn.Position = UDim2.new(1, -(BtnSize + 10), 0, 7)
	CloseBtn.BackgroundColor3 = C_RED
	CloseBtn.BorderSizePixel = 0
	CloseBtn.Text = "X"
	CloseBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	CloseBtn.TextSize = 14
	CloseBtn.Font = Enum.Font.GothamBold
	CloseBtn.AutoButtonColor = false
	CloseBtn.ZIndex = 5
	CloseBtn.Parent = TopBar

	local CloseCorner = Instance.new("UICorner")
	CloseCorner.CornerRadius = UDim.new(0, 8)
	CloseCorner.Parent = CloseBtn

	local CloseStroke = Instance.new("UIStroke")
	CloseStroke.Color = Color3.fromRGB(255, 200, 200)
	CloseStroke.Thickness = 1
	CloseStroke.Transparency = 0.5
	CloseStroke.Parent = CloseBtn

	CloseBtn.MouseEnter:Connect(function()
		TweenService:Create(CloseBtn, TweenInfo.new(0.15), {BackgroundColor3 = C_RED_HOVER}):Play()
	end)
	CloseBtn.MouseLeave:Connect(function()
		TweenService:Create(CloseBtn, TweenInfo.new(0.15), {BackgroundColor3 = C_RED}):Play()
	end)

	local SideMenu = Instance.new("ScrollingFrame")
	SideMenu.Size = UDim2.new(0, 160, 1, -42)
	SideMenu.Position = UDim2.new(0, 0, 0, 42)
	SideMenu.BackgroundColor3 = C_SIDEBAR
	SideMenu.BackgroundTransparency = 0.25
	SideMenu.BorderSizePixel = 0
	SideMenu.ScrollBarThickness = 2
	SideMenu.ScrollBarImageColor3 = C_ACCENT
	SideMenu.CanvasSize = UDim2.new(0, 0, 0, 0)
	SideMenu.ClipsDescendants = true
	SideMenu.ScrollBarImageTransparency = 0.5
	SideMenu.ZIndex = 1
	SideMenu.Parent = MainFrame

	local SideList = Instance.new("UIListLayout")
	SideList.Padding = UDim.new(0, 3)
	SideList.SortOrder = Enum.SortOrder.LayoutOrder
	SideList.Parent = SideMenu

	local SidePad = Instance.new("UIPadding")
	SidePad.PaddingTop = UDim.new(0, 8)
	SidePad.PaddingBottom = UDim.new(0, 8)
	SidePad.Parent = SideMenu

	SideList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		SideMenu.CanvasSize = UDim2.new(0, 0, 0, SideList.AbsoluteContentSize.Y + 16)
	end)

	local VDivider = Instance.new("Frame")
	VDivider.Size = UDim2.new(0, 1, 1, -42)
	VDivider.Position = UDim2.new(0, 160, 0, 42)
	VDivider.BackgroundColor3 = C_DIVIDER
	VDivider.BorderSizePixel = 0
	VDivider.ZIndex = 2
	VDivider.Parent = MainFrame

	local ContentHolder = Instance.new("Frame")
	ContentHolder.Size = UDim2.new(1, -161, 1, -42)
	ContentHolder.Position = UDim2.new(0, 161, 0, 42)
	ContentHolder.BackgroundColor3 = C_CONTENT
	ContentHolder.BackgroundTransparency = 0.35
	ContentHolder.BorderSizePixel = 0
	ContentHolder.ClipsDescendants = true
	ContentHolder.ZIndex = 1
	ContentHolder.Parent = MainFrame

	local HomePanel = Instance.new("ScrollingFrame")
	HomePanel.Size = UDim2.new(1, 0, 1, 0)
	HomePanel.BackgroundTransparency = 1
	HomePanel.BorderSizePixel = 0
	HomePanel.ScrollBarThickness = 3
	HomePanel.ScrollBarImageColor3 = C_ACCENT
	HomePanel.ScrollBarImageTransparency = 0.6
	HomePanel.CanvasSize = UDim2.new(0, 0, 0, 500)
	HomePanel.Visible = true
	HomePanel.ZIndex = 1
	HomePanel.Parent = ContentHolder

	local HomeHeader = Instance.new("Frame")
	HomeHeader.Size = UDim2.new(1, -16, 0, 34)
	HomeHeader.Position = UDim2.new(0, 8, 0, 8)
	HomeHeader.BackgroundTransparency = 1
	HomeHeader.Parent = HomePanel

	local HomeTitle = Instance.new("TextLabel")
	HomeTitle.Size = UDim2.new(1, 0, 1, 0)
	HomeTitle.BackgroundTransparency = 1
	HomeTitle.Text = "PROFILE"
	HomeTitle.TextColor3 = C_TEXT
	HomeTitle.TextSize = 15
	HomeTitle.Font = Enum.Font.GothamBold
	HomeTitle.TextXAlignment = Enum.TextXAlignment.Left
	HomeTitle.Parent = HomeHeader

	local HeaderLine = Instance.new("Frame")
	HeaderLine.Size = UDim2.new(0, 40, 0, 2)
	HeaderLine.Position = UDim2.new(0, 0, 1, 2)
	HeaderLine.BackgroundColor3 = C_ACCENT
	HeaderLine.BorderSizePixel = 0
	HeaderLine.Parent = HomeHeader

	local HeaderLineGrad = Instance.new("UIGradient")
	HeaderLineGrad.Transparency = NumberSequence.new{
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1)
	}
	HeaderLineGrad.Parent = HeaderLine

	local ProfileCard = Instance.new("Frame")
	ProfileCard.Size = UDim2.new(1, -16, 0, 200)
	ProfileCard.Position = UDim2.new(0, 8, 0, 50)
	ProfileCard.BackgroundColor3 = C_BOX_2
	ProfileCard.BackgroundTransparency = 0.15
	ProfileCard.BorderSizePixel = 0
	ProfileCard.Parent = HomePanel

	local ProfileCorner = Instance.new("UICorner")
	ProfileCorner.CornerRadius = UDim.new(0, 10)
	ProfileCorner.Parent = ProfileCard

	local ProfileStroke = Instance.new("UIStroke")
	ProfileStroke.Color = C_GREEN
	ProfileStroke.Thickness = 1.5
	ProfileStroke.Transparency = 0.4
	ProfileStroke.Parent = ProfileCard

	local CardGrad = Instance.new("UIGradient")
	CardGrad.Color = ColorSequence.new{
		ColorSequenceKeypoint.new(0, Color3.fromRGB(28, 34, 44)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(20, 22, 30))
	}
	CardGrad.Rotation = 45
	CardGrad.Parent = ProfileCard

	local CardGrid = Instance.new("Frame")
	CardGrid.Size = UDim2.new(1, 0, 1, 0)
	CardGrid.BackgroundTransparency = 1
	CardGrid.ClipsDescendants = true
	CardGrid.ZIndex = 2
	CardGrid.Parent = ProfileCard

	local CardGridCorner = Instance.new("UICorner")
	CardGridCorner.CornerRadius = UDim.new(0, 10)
	CardGridCorner.Parent = CardGrid

	for i = 0, 20 do
		local vl = Instance.new("Frame")
		vl.Size = UDim2.new(0, 1, 1, 0)
		vl.Position = UDim2.new(i/20, 0, 0, 0)
		vl.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		vl.BackgroundTransparency = 0.97
		vl.BorderSizePixel = 0
		vl.ZIndex = 2
		vl.Parent = CardGrid
	end

	local AvatarFrame = Instance.new("Frame")
	AvatarFrame.Size = UDim2.new(0, 120, 0, 120)
	AvatarFrame.Position = UDim2.new(0, 16, 0, 16)
	AvatarFrame.BackgroundColor3 = Color3.fromRGB(12, 14, 20)
	AvatarFrame.BorderSizePixel = 0
	AvatarFrame.ZIndex = 3
	AvatarFrame.Parent = ProfileCard

	local AvatarFrameCorner = Instance.new("UICorner")
	AvatarFrameCorner.CornerRadius = UDim.new(0, 10)
	AvatarFrameCorner.Parent = AvatarFrame

	local AvatarGrad = Instance.new("UIGradient")
	AvatarGrad.Color = ColorSequence.new{
		ColorSequenceKeypoint.new(0, C_GREEN),
		ColorSequenceKeypoint.new(0.5, C_ACCENT),
		ColorSequenceKeypoint.new(1, C_GREEN)
	}
	AvatarGrad.Rotation = 45
	AvatarGrad.Parent = AvatarFrame

	local AvatarFrameStroke = Instance.new("UIStroke")
	AvatarFrameStroke.Color = C_GREEN
	AvatarFrameStroke.Thickness = 2
	AvatarFrameStroke.Transparency = 0.1
	AvatarFrameStroke.Parent = AvatarFrame

	local AvatarInner = Instance.new("Frame")
	AvatarInner.Size = UDim2.new(1, -6, 1, -6)
	AvatarInner.Position = UDim2.new(0, 3, 0, 3)
	AvatarInner.BackgroundColor3 = Color3.fromRGB(12, 14, 20)
	AvatarInner.BorderSizePixel = 0
	AvatarInner.ZIndex = 4
	AvatarInner.Parent = AvatarFrame

	local AvatarInnerCorner = Instance.new("UICorner")
	AvatarInnerCorner.CornerRadius = UDim.new(0, 8)
	AvatarInnerCorner.Parent = AvatarInner

	local AvatarImage = Instance.new("ImageLabel")
	AvatarImage.Size = UDim2.new(1, 0, 1, 0)
	AvatarImage.BackgroundTransparency = 1
	AvatarImage.Image = "rbxthumb://type=AvatarHeadShot&id=" .. Player.UserId .. "&w=150&h=150"
	AvatarImage.ScaleType = Enum.ScaleType.Fit
	AvatarImage.ZIndex = 5
	AvatarImage.Parent = AvatarInner

	local AvatarImgCorner = Instance.new("UICorner")
	AvatarImgCorner.CornerRadius = UDim.new(0, 8)
	AvatarImgCorner.Parent = AvatarImage

	local OnlineDot = Instance.new("Frame")
	OnlineDot.Size = UDim2.new(0, 18, 0, 18)
	OnlineDot.Position = UDim2.new(1, -10, 1, -10)
	OnlineDot.BackgroundColor3 = C_GREEN
	OnlineDot.BorderSizePixel = 0
	OnlineDot.ZIndex = 6
	OnlineDot.Parent = AvatarFrame

	local OnlineDotCorner = Instance.new("UICorner")
	OnlineDotCorner.CornerRadius = UDim.new(1, 0)
	OnlineDotCorner.Parent = OnlineDot

	local OnlineDotInner = Instance.new("Frame")
	OnlineDotInner.Size = UDim2.new(1, -6, 1, -6)
	OnlineDotInner.Position = UDim2.new(0, 3, 0, 3)
	OnlineDotInner.BackgroundColor3 = C_GREEN
	OnlineDotInner.BorderSizePixel = 0
	OnlineDotInner.ZIndex = 7
	OnlineDotInner.Parent = OnlineDot

	local OnlineDotInnerCorner = Instance.new("UICorner")
	OnlineDotInnerCorner.CornerRadius = UDim.new(1, 0)
	OnlineDotInnerCorner.Parent = OnlineDotInner

	task.spawn(function()
		while OnlineDot.Parent do
			TweenService:Create(OnlineDot, TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
				BackgroundTransparency = 0.7
			}):Play()
			task.wait(1)
			if not OnlineDot.Parent then break end
			TweenService:Create(OnlineDot, TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
				BackgroundTransparency = 0
			}):Play()
			task.wait(1)
		end
	end)

	local AvatarName = Instance.new("TextLabel")
	AvatarName.Size = UDim2.new(1, -8, 0, 16)
	AvatarName.Position = UDim2.new(0, 4, 1, 4)
	AvatarName.BackgroundTransparency = 1
	AvatarName.Text = Player.DisplayName
	AvatarName.TextColor3 = C_TEXT
	AvatarName.TextSize = 11
	AvatarName.Font = Enum.Font.GothamBold
	AvatarName.TextTruncate = Enum.TextTruncate.AtEnd
	AvatarName.ZIndex = 6
	AvatarName.Parent = AvatarFrame

	local InfoX = 152

	local NameLabel = Instance.new("TextLabel")
	NameLabel.Size = UDim2.new(0, 80, 0, 20)
	NameLabel.Position = UDim2.new(0, InfoX, 0, 20)
	NameLabel.BackgroundTransparency = 1
	NameLabel.Text = "NAME USER"
	NameLabel.TextColor3 = C_GOLD
	NameLabel.TextSize = 13
	NameLabel.Font = Enum.Font.GothamBold
	NameLabel.TextXAlignment = Enum.TextXAlignment.Left
	NameLabel.ZIndex = 3
	NameLabel.Parent = ProfileCard

	local NameValue = Instance.new("TextLabel")
	NameValue.Size = UDim2.new(1, InfoX + 82, 0, 20)
	NameValue.Position = UDim2.new(0, InfoX + 82, 0, 20)
	NameValue.BackgroundTransparency = 1
	NameValue.Text = Player.Name
	NameValue.TextColor3 = C_TEXT
	NameValue.TextSize = 13
	NameValue.Font = Enum.Font.Gotham
	NameValue.TextXAlignment = Enum.TextXAlignment.Left
	NameValue.TextTruncate = Enum.TextTruncate.AtEnd
	NameValue.ZIndex = 3
	NameValue.Parent = ProfileCard

	local IdLabel = Instance.new("TextLabel")
	IdLabel.Size = UDim2.new(0, 80, 0, 20)
	IdLabel.Position = UDim2.new(0, InfoX, 0, 46)
	IdLabel.BackgroundTransparency = 1
	IdLabel.Text = "ID USER:"
	IdLabel.TextColor3 = C_GOLD
	IdLabel.TextSize = 13
	IdLabel.Font = Enum.Font.GothamBold
	IdLabel.TextXAlignment = Enum.TextXAlignment.Left
	IdLabel.ZIndex = 3
	IdLabel.Parent = ProfileCard

	local IdValue = Instance.new("TextLabel")
	IdValue.Size = UDim2.new(1, InfoX + 82, 0, 20)
	IdValue.Position = UDim2.new(0, InfoX + 82, 0, 46)
	IdValue.BackgroundTransparency = 1
	IdValue.Text = tostring(Player.UserId)
	IdValue.TextColor3 = C_TEXT
	IdValue.TextSize = 13
	IdValue.Font = Enum.Font.Gotham
	IdValue.TextXAlignment = Enum.TextXAlignment.Left
	IdValue.ZIndex = 3
	IdValue.Parent = ProfileCard

	local StatusLabel = Instance.new("TextLabel")
	StatusLabel.Size = UDim2.new(0, 80, 0, 22)
	StatusLabel.Position = UDim2.new(0, InfoX, 0, 72)
	StatusLabel.BackgroundTransparency = 1
	StatusLabel.Text = "Status:"
	StatusLabel.TextColor3 = C_GOLD
	StatusLabel.TextSize = 13
	StatusLabel.Font = Enum.Font.GothamBold
	StatusLabel.TextXAlignment = Enum.TextXAlignment.Left
	StatusLabel.ZIndex = 3
	StatusLabel.Parent = ProfileCard

	local StatusBadge = Instance.new("Frame")
	StatusBadge.Size = UDim2.new(0, 90, 0, 22)
	StatusBadge.Position = UDim2.new(0, InfoX + 82, 0, 72)
	StatusBadge.BackgroundColor3 = C_GREEN_DARK
	StatusBadge.BorderSizePixel = 0
	StatusBadge.ZIndex = 3
	StatusBadge.Parent = ProfileCard

	local StatusBadgeCorner = Instance.new("UICorner")
	StatusBadgeCorner.CornerRadius = UDim.new(0, 6)
	StatusBadgeCorner.Parent = StatusBadge

	local StatusBadgeStroke = Instance.new("UIStroke")
	StatusBadgeStroke.Color = C_GREEN
	StatusBadgeStroke.Thickness = 1
	StatusBadgeStroke.Transparency = 0.2
	StatusBadgeStroke.Parent = StatusBadge

	local StatusDot = Instance.new("Frame")
	StatusDot.Size = UDim2.new(0, 8, 0, 8)
	StatusDot.Position = UDim2.new(0, 8, 0.5, -4)
	StatusDot.BackgroundColor3 = C_GREEN
	StatusDot.BorderSizePixel = 0
	StatusDot.ZIndex = 4
	StatusDot.Parent = StatusBadge

	local StatusDotCorner = Instance.new("UICorner")
	StatusDotCorner.CornerRadius = UDim.new(1, 0)
	StatusDotCorner.Parent = StatusDot

	local StatusText = Instance.new("TextLabel")
	StatusText.Size = UDim2.new(1, -25, 1, 0)
	StatusText.Position = UDim2.new(0, 22, 0, 0)
	StatusText.BackgroundTransparency = 1
	StatusText.Text = "Activo"
	StatusText.TextColor3 = C_GREEN
	StatusText.TextSize = 12
	StatusText.Font = Enum.Font.GothamBold
	StatusText.TextXAlignment = Enum.TextXAlignment.Left
	StatusText.ZIndex = 4
	StatusText.Parent = StatusBadge

	local FooterLine = Instance.new("Frame")
	FooterLine.Size = UDim2.new(1, -32, 0, 1)
	FooterLine.Position = UDim2.new(0, 16, 0, 165)
	FooterLine.BackgroundColor3 = C_DIVIDER
	FooterLine.BorderSizePixel = 0
	FooterLine.ZIndex = 3
	FooterLine.Parent = ProfileCard

	local VersionLabel = Instance.new("TextLabel")
	VersionLabel.Size = UDim2.new(0, 100, 0, 20)
	VersionLabel.Position = UDim2.new(0, 16, 0, 172)
	VersionLabel.BackgroundTransparency = 1
	VersionLabel.Text = "BETA"
	VersionLabel.TextColor3 = C_TEXT_DIM
	VersionLabel.TextSize = 11
	VersionLabel.Font = Enum.Font.Gotham
	VersionLabel.TextXAlignment = Enum.TextXAlignment.Left
	VersionLabel.ZIndex = 3
	VersionLabel.Parent = ProfileCard

	local BuildLabel = Instance.new("TextLabel")
	BuildLabel.Size = UDim2.new(0, 150, 0, 20)
	BuildLabel.Position = UDim2.new(1, -166, 0, 172)
	BuildLabel.BackgroundTransparency = 1
	BuildLabel.Text = "OFICIAL"
	BuildLabel.TextColor3 = C_TEXT_DIM
	BuildLabel.TextSize = 11
	BuildLabel.Font = Enum.Font.Gotham
	BuildLabel.TextXAlignment = Enum.TextXAlignment.Right
	BuildLabel.ZIndex = 3
	BuildLabel.Parent = ProfileCard

	local CommunitySection = Instance.new("Frame")
	CommunitySection.Size = UDim2.new(1, -16, 0, 100)
	CommunitySection.Position = UDim2.new(0, 8, 0, 262)
	CommunitySection.BackgroundColor3 = C_BOX
	CommunitySection.BackgroundTransparency = 0.15
	CommunitySection.BorderSizePixel = 0
	CommunitySection.Parent = HomePanel

	local CommunityCorner = Instance.new("UICorner")
	CommunityCorner.CornerRadius = UDim.new(0, 10)
	CommunityCorner.Parent = CommunitySection

	local CommunityGrad = Instance.new("UIGradient")
	CommunityGrad.Color = ColorSequence.new{
		ColorSequenceKeypoint.new(0, Color3.fromRGB(30, 38, 60)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(24, 27, 40))
	}
	CommunityGrad.Rotation = 45
	CommunityGrad.Parent = CommunitySection

	local CommunityStroke = Instance.new("UIStroke")
	CommunityStroke.Color = C_DISCORD
	CommunityStroke.Thickness = 1
	CommunityStroke.Transparency = 0.3
	CommunityStroke.Parent = CommunitySection

	local CommunityTitle = Instance.new("TextLabel")
	CommunityTitle.Size = UDim2.new(1, -20, 0, 22)
	CommunityTitle.Position = UDim2.new(0, 14, 0, 10)
	CommunityTitle.BackgroundTransparency = 1
	CommunityTitle.Text = "ÚNETE A NUESTRO DISCORD"
	CommunityTitle.TextColor3 = C_TEXT
	CommunityTitle.TextSize = 13
	CommunityTitle.Font = Enum.Font.GothamBold
	CommunityTitle.TextXAlignment = Enum.TextXAlignment.Left
	CommunityTitle.Parent = CommunitySection

	local CommunitySub = Instance.new("TextLabel")
	CommunitySub.Size = UDim2.new(1, -20, 0, 16)
	CommunitySub.Position = UDim2.new(0, 14, 0, 32)
	CommunitySub.BackgroundTransparency = 1
	CommunitySub.Text = "Únete al servidor de Discord para soporte y updates"
	CommunitySub.TextColor3 = C_TEXT_DIM
	CommunitySub.TextSize = 11
	CommunitySub.Font = Enum.Font.Gotham
	CommunitySub.TextXAlignment = Enum.TextXAlignment.Left
	CommunitySub.Parent = CommunitySection

	local DiscordBtn = Instance.new("TextButton")
	DiscordBtn.Size = UDim2.new(0, 170, 0, 34)
	DiscordBtn.Position = UDim2.new(0, 14, 0, 54)
	DiscordBtn.BackgroundColor3 = C_DISCORD
	DiscordBtn.BorderSizePixel = 0
	DiscordBtn.Text = "COPIAR DISCORD"
	DiscordBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	DiscordBtn.TextSize = 12
	DiscordBtn.Font = Enum.Font.GothamBold
	DiscordBtn.AutoButtonColor = false
	DiscordBtn.Parent = CommunitySection

	local DiscordBtnCorner = Instance.new("UICorner")
	DiscordBtnCorner.CornerRadius = UDim.new(0, 8)
	DiscordBtnCorner.Parent = DiscordBtn

	local DiscordBtnStroke = Instance.new("UIStroke")
	DiscordBtnStroke.Color = Color3.fromRGB(255, 255, 255)
	DiscordBtnStroke.Thickness = 1
	DiscordBtnStroke.Transparency = 0.75
	DiscordBtnStroke.Parent = DiscordBtn

	local LinkLabel = Instance.new("TextLabel")
	LinkLabel.Size = UDim2.new(1, -200, 0, 20)
	LinkLabel.Position = UDim2.new(0, 194, 0, 61)
	LinkLabel.BackgroundTransparency = 1
	LinkLabel.Text = "https://discord.gg/cXu9GzpKxv"
	LinkLabel.TextColor3 = C_LINK
	LinkLabel.TextSize = 11
	LinkLabel.Font = Enum.Font.Gotham
	LinkLabel.TextXAlignment = Enum.TextXAlignment.Left
	LinkLabel.TextTruncate = Enum.TextTruncate.AtEnd
	LinkLabel.Parent = CommunitySection

	local copied = false
	DiscordBtn.MouseEnter:Connect(function()
		if not copied then
			TweenService:Create(DiscordBtn, TweenInfo.new(0.15), {BackgroundColor3 = C_DISCORD_H}):Play()
		end
	end)
	DiscordBtn.MouseLeave:Connect(function()
		if not copied then
			TweenService:Create(DiscordBtn, TweenInfo.new(0.15), {BackgroundColor3 = C_DISCORD}):Play()
		end
	end)
	DiscordBtn.MouseButton1Click:Connect(function()
		pcall(function() setclipboard(DISCORD_URL) end)
		copied = true
		DiscordBtn.Text = "✓  COPIADO"
		TweenService:Create(DiscordBtn, TweenInfo.new(0.15), {BackgroundColor3 = C_GREEN}):Play()
		task.wait(1.5)
		copied = false
		DiscordBtn.Text = "COPIAR DISCORD"
		TweenService:Create(DiscordBtn, TweenInfo.new(0.25), {BackgroundColor3 = C_DISCORD}):Play()
	end)

	local InfoRow = Instance.new("Frame")
	InfoRow.Size = UDim2.new(1, -16, 0, 60)
	InfoRow.Position = UDim2.new(0, 8, 0, 372)
	InfoRow.BackgroundTransparency = 1
	InfoRow.Parent = HomePanel

	local function CreateStatCard(x, w, title, value, color)
		local card = Instance.new("Frame")
		card.Size = UDim2.new(0, w, 1, 0)
		card.Position = UDim2.new(0, x, 0, 0)
		card.BackgroundColor3 = C_BOX
		card.BackgroundTransparency = 0.15
		card.BorderSizePixel = 0
		card.Parent = InfoRow

		local cc = Instance.new("UICorner")
		cc.CornerRadius = UDim.new(0, 8)
		cc.Parent = card

		local cs = Instance.new("UIStroke")
		cs.Color = color
		cs.Thickness = 1
		cs.Transparency = 0.5
		cs.Parent = card

		local accent = Instance.new("Frame")
		accent.Size = UDim2.new(0, 3, 0, 22)
		accent.Position = UDim2.new(0, 8, 0.5, -11)
		accent.BackgroundColor3 = color
		accent.BorderSizePixel = 0
		accent.Parent = card

		local accentCorner = Instance.new("UICorner")
		accentCorner.CornerRadius = UDim.new(1, 0)
		accentCorner.Parent = accent

		local t = Instance.new("TextLabel")
		t.Size = UDim2.new(1, -20, 0, 16)
		t.Position = UDim2.new(0, 16, 0, 10)
		t.BackgroundTransparency = 1
		t.Text = title
		t.TextColor3 = C_TEXT_DIM
		t.TextSize = 10
		t.Font = Enum.Font.Gotham
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.Parent = card

		local v = Instance.new("TextLabel")
		v.Size = UDim2.new(1, -20, 0, 20)
		v.Position = UDim2.new(0, 16, 0, 28)
		v.BackgroundTransparency = 1
		v.Text = value
		v.TextColor3 = color
		v.TextSize = 14
		v.Font = Enum.Font.GothamBold
		v.TextXAlignment = Enum.TextXAlignment.Left
		v.Parent = card

		return v, accent, card, cs
	end

	CreateStatCard(0, 122, "STATUS", "ONLINE", C_GREEN)
	local PingValueLabel, PingAccent, PingCard, PingStroke = CreateStatCard(130, 122, "PING", "...", C_ACCENT)
	CreateStatCard(260, 112, "BUILD", "STABLE", C_GOLD)

	local function GetPing()
		local ping = 0
		pcall(function()
			ping = math.floor(Player:GetNetworkPing() * 1000)
		end)
		if ping <= 0 then
			ping = math.random(28, 65)
		end
		return ping
	end

	local currentDisplayPing = GetPing()
	local targetPing = currentDisplayPing

	task.spawn(function()
		while PingValueLabel.Parent do
			targetPing = GetPing()
			task.wait(1)
		end
	end)

	task.spawn(function()
		while PingValueLabel.Parent do
			currentDisplayPing = currentDisplayPing + (targetPing - currentDisplayPing) * 0.15

			local shownPing = math.floor(currentDisplayPing + 0.5)

			local color
			if shownPing < 60 then
				color = C_GREEN
			elseif shownPing < 100 then
				color = C_ACCENT
			elseif shownPing < 180 then
				color = C_GOLD
			else
				color = C_RED
			end

			PingValueLabel.Text = shownPing .. " ms"
			PingValueLabel.TextColor3 = color
			PingAccent.BackgroundColor3 = color
			PingStroke.Color = color

			RunService.Heartbeat:Wait()
		end
	end)

	local SettingsPanel = Instance.new("ScrollingFrame")
	SettingsPanel.Size = UDim2.new(1, 0, 1, 0)
	SettingsPanel.BackgroundTransparency = 1
	SettingsPanel.BorderSizePixel = 0
	SettingsPanel.ScrollBarThickness = 2
	SettingsPanel.ScrollBarImageColor3 = C_ACCENT
	SettingsPanel.ScrollBarImageTransparency = 0.5
	SettingsPanel.CanvasSize = UDim2.new(0, 0, 0, 0)
	SettingsPanel.Visible = false
	SettingsPanel.ZIndex = 1
	SettingsPanel.Parent = ContentHolder

	local AnimPanel = Instance.new("ScrollingFrame")
	AnimPanel.Size = UDim2.new(1, 0, 1, 0)
	AnimPanel.BackgroundTransparency = 1
	AnimPanel.BorderSizePixel = 0
	AnimPanel.ScrollBarThickness = 2
	AnimPanel.ScrollBarImageColor3 = C_ACCENT
	AnimPanel.ScrollBarImageTransparency = 0.5
	AnimPanel.CanvasSize = UDim2.new(0, 0, 0, 0)
	AnimPanel.AutomaticCanvasSize = Enum.AutomaticSize.Y
	AnimPanel.Visible = false
	AnimPanel.ZIndex = 1
	AnimPanel.Parent = ContentHolder

	local AnimLayout = Instance.new("UIListLayout")
	AnimLayout.Padding = UDim.new(0, 8)
	AnimLayout.SortOrder = Enum.SortOrder.LayoutOrder
	AnimLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	AnimLayout.Parent = AnimPanel

	local AnimPad = Instance.new("UIPadding")
	AnimPad.PaddingTop = UDim.new(0, 10)
	AnimPad.PaddingBottom = UDim.new(0, 10)
	AnimPad.PaddingLeft = UDim.new(0, 10)
	AnimPad.PaddingRight = UDim.new(0, 10)
	AnimPad.Parent = AnimPanel

	local AnimToggleFrame = Instance.new("Frame")
	AnimToggleFrame.Size = UDim2.new(1, -20, 0, 50)
	AnimToggleFrame.BackgroundColor3 = C_BOX
	AnimToggleFrame.BackgroundTransparency = 0.15
	AnimToggleFrame.BorderSizePixel = 0
	AnimToggleFrame.LayoutOrder = 0
	AnimToggleFrame.Parent = AnimPanel

	local AnimToggleCorner = Instance.new("UICorner")
	AnimToggleCorner.CornerRadius = UDim.new(0, 10)
	AnimToggleCorner.Parent = AnimToggleFrame

	local AnimToggleStroke = Instance.new("UIStroke")
	AnimToggleStroke.Color = C_DIVIDER
	AnimToggleStroke.Thickness = 1
	AnimToggleStroke.Transparency = 0.4
	AnimToggleStroke.Parent = AnimToggleFrame

	local AnimToggleLabel = Instance.new("TextLabel")
	AnimToggleLabel.Size = UDim2.new(1, -80, 0, 20)
	AnimToggleLabel.Position = UDim2.new(0, 16, 0, 8)
	AnimToggleLabel.BackgroundTransparency = 1
	AnimToggleLabel.Text = "ANIMACIONES"
	AnimToggleLabel.TextColor3 = C_TEXT
	AnimToggleLabel.TextSize = 13
	AnimToggleLabel.Font = Enum.Font.GothamBold
	AnimToggleLabel.TextXAlignment = Enum.TextXAlignment.Left
	AnimToggleLabel.Parent = AnimToggleFrame

	local AnimToggleSub = Instance.new("TextLabel")
	AnimToggleSub.Size = UDim2.new(1, -80, 0, 14)
	AnimToggleSub.Position = UDim2.new(0, 16, 0, 28)
	AnimToggleSub.BackgroundTransparency = 1
	AnimToggleSub.Text = "CAMBIA LAS ANIMACIONES DE TU PERSONAJE"
	AnimToggleSub.TextColor3 = C_TEXT_DIM
	AnimToggleSub.TextSize = 10
	AnimToggleSub.Font = Enum.Font.Gotham
	AnimToggleSub.TextXAlignment = Enum.TextXAlignment.Left
	AnimToggleSub.Parent = AnimToggleFrame

	local AnimToggleBtn = Instance.new("TextButton")
	AnimToggleBtn.Size = UDim2.new(0, 52, 0, 28)
	AnimToggleBtn.Position = UDim2.new(1, -68, 0.5, -14)
	AnimToggleBtn.BackgroundColor3 = Color3.fromRGB(40, 44, 56)
	AnimToggleBtn.BorderSizePixel = 0
	AnimToggleBtn.Text = ""
	AnimToggleBtn.AutoButtonColor = false
	AnimToggleBtn.Parent = AnimToggleFrame

	local ToggleCorner = Instance.new("UICorner")
	ToggleCorner.CornerRadius = UDim.new(1, 0)
	ToggleCorner.Parent = AnimToggleBtn

	local ToggleKnob = Instance.new("Frame")
	ToggleKnob.Size = UDim2.new(0, 22, 0, 22)
	ToggleKnob.Position = UDim2.new(0, 3, 0.5, -11)
	ToggleKnob.BackgroundColor3 = Color3.fromRGB(180, 185, 200)
	ToggleKnob.BorderSizePixel = 0
	ToggleKnob.Parent = AnimToggleBtn

	local ToggleKnobCorner = Instance.new("UICorner")
	ToggleKnobCorner.CornerRadius = UDim.new(1, 0)
	ToggleKnobCorner.Parent = ToggleKnob

	local AnimListContainer = Instance.new("Frame")
	AnimListContainer.Size = UDim2.new(1, 0, 0, 0)
	AnimListContainer.AutomaticSize = Enum.AutomaticSize.Y
	AnimListContainer.BackgroundTransparency = 1
	AnimListContainer.LayoutOrder = 1
	AnimListContainer.Visible = false
	AnimListContainer.Parent = AnimPanel

	local AnimListLayout = Instance.new("UIListLayout")
	AnimListLayout.Padding = UDim.new(0, 6)
	AnimListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	AnimListLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	AnimListLayout.Parent = AnimListContainer

	local animState = { enabled = false, gui = nil }
	local animSelected = {}

	local function ApplyAnims(ids)
		local char = Player.Character
		if not char then return end
		local hum = char:FindFirstChildOfClass("Humanoid")
		local Animate = char:FindFirstChild("Animate")
		if not Animate or not hum then return end
		local animator = hum:FindFirstChildOfClass("Animator")
		if animator then
			for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
				track:Stop(0)
			end
		end
		local function setAnimId(parentName, childName, newId)
			local parentObj = Animate:FindFirstChild(parentName)
			if parentObj then
				local animObj = parentObj:FindFirstChild(childName)
				if animObj and animObj:IsA("Animation") then
					animObj.AnimationId = newId or "rbxassetid://0"
				end
			end
		end
		setAnimId("idle", "Animation1", ids.idle1)
		setAnimId("idle", "Animation2", ids.idle2)
		setAnimId("walk", "WalkAnim", ids.walk)
		setAnimId("run", "RunAnim", ids.run)
		setAnimId("jump", "JumpAnim", ids.jump)
		setAnimId("fall", "FallAnim", ids.fall)
		Animate.Enabled = false
		task.wait(0.03)
		Animate.Enabled = true
		if hum.Health > 0 then
			hum:ChangeState(Enum.HumanoidStateType.Landed)
		end
	end

	local function CreateAnimButton(name, ids)
		local Btn = Instance.new("TextButton")
		Btn.Size = UDim2.new(1, -8, 0, 44)
		Btn.Text = ""
		Btn.BackgroundColor3 = C_BOX_2
		Btn.BackgroundTransparency = 0.05
		Btn.AutoButtonColor = false
		Btn.Parent = AnimListContainer

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 10)
		corner.Parent = Btn

		local stroke = Instance.new("UIStroke")
		stroke.Color = C_DIVIDER
		stroke.Thickness = 1
		stroke.Transparency = 0.3
		stroke.Parent = Btn

		local accentBar = Instance.new("Frame")
		accentBar.Size = UDim2.new(0, 3, 0, 20)
		accentBar.Position = UDim2.new(0, 0, 0.5, -10)
		accentBar.BackgroundColor3 = C_ACCENT
		accentBar.BorderSizePixel = 0
		accentBar.Parent = Btn

		local accentCorner = Instance.new("UICorner")
		accentCorner.CornerRadius = UDim.new(1, 0)
		accentCorner.Parent = accentBar

		local txt = Instance.new("TextLabel")
		txt.Size = UDim2.new(1, -60, 0, 20)
		txt.Position = UDim2.new(0, 20, 0, 6)
		txt.BackgroundTransparency = 1
		txt.Text = name
		txt.TextColor3 = C_TEXT
		txt.Font = Enum.Font.GothamBold
		txt.TextSize = 13
		txt.TextXAlignment = Enum.TextXAlignment.Left
		txt.Parent = Btn

		local sub = Instance.new("TextLabel")
		sub.Size = UDim2.new(1, -60, 0, 14)
		sub.Position = UDim2.new(0, 20, 0, 24)
		sub.BackgroundTransparency = 1
		sub.Text = "Animación completa · 6 tracks"
		sub.TextColor3 = C_TEXT_DIM
		sub.Font = Enum.Font.Gotham
		sub.TextSize = 10
		sub.TextXAlignment = Enum.TextXAlignment.Left
		sub.Parent = Btn

		local arrow = Instance.new("TextLabel")
		arrow.Size = UDim2.new(0, 30, 1, 0)
		arrow.Position = UDim2.new(1, -35, 0, 0)
		arrow.BackgroundTransparency = 1
		arrow.Text = "›"
		arrow.TextColor3 = C_TEXT_DIM
		arrow.Font = Enum.Font.GothamBold
		arrow.TextSize = 22
		arrow.Parent = Btn

		Btn.MouseEnter:Connect(function()
			TweenService:Create(Btn, TweenInfo.new(0.22), {BackgroundColor3 = C_BOX}):Play()
			TweenService:Create(stroke, TweenInfo.new(0.22), {Color = C_ACCENT, Transparency = 0.1}):Play()
			TweenService:Create(txt, TweenInfo.new(0.22), {TextColor3 = C_WHITE}):Play()
			TweenService:Create(arrow, TweenInfo.new(0.22), {TextColor3 = C_ACCENT, Position = UDim2.new(1, -30, 0, 0)}):Play()
		end)

		Btn.MouseLeave:Connect(function()
			TweenService:Create(Btn, TweenInfo.new(0.22), {BackgroundColor3 = C_BOX_2}):Play()
			TweenService:Create(stroke, TweenInfo.new(0.22), {Color = C_DIVIDER, Transparency = 0.3}):Play()
			TweenService:Create(txt, TweenInfo.new(0.22), {TextColor3 = C_TEXT}):Play()
			TweenService:Create(arrow, TweenInfo.new(0.22), {TextColor3 = C_TEXT_DIM, Position = UDim2.new(1, -35, 0, 0)}):Play()
		end)

		Btn.MouseButton1Click:Connect(function()
			TweenService:Create(Btn, TweenInfo.new(0.1), {BackgroundColor3 = C_ACCENT_SOFT}):Play()
			TweenService:Create(accentBar, TweenInfo.new(0.1), {BackgroundColor3 = C_WHITE}):Play()
			task.delay(0.15, function()
				TweenService:Create(Btn, TweenInfo.new(0.3), {BackgroundColor3 = C_BOX_2}):Play()
				TweenService:Create(accentBar, TweenInfo.new(0.3), {BackgroundColor3 = C_ACCENT}):Play()
			end)
			animSelected = ids
			ApplyAnims(ids)
		end)

		return Btn
	end

	local anims = {
		{name = "Astronaut", ids = {
			idle1 = "http://www.roblox.com/asset/?id=891621366",
			idle2 = "http://www.roblox.com/asset/?id=891633237",
			walk  = "http://www.roblox.com/asset/?id=891667138",
			run   = "http://www.roblox.com/asset/?id=891636393",
			jump  = "http://www.roblox.com/asset/?id=891627522",
			fall  = "http://www.roblox.com/asset/?id=891617961"
		}},
		{name = "Bubbly", ids = {
			idle1 = "http://www.roblox.com/asset/?id=910004836",
			idle2 = "http://www.roblox.com/asset/?id=910009958",
			walk  = "http://www.roblox.com/asset/?id=910034870",
			run   = "http://www.roblox.com/asset/?id=910025107",
			jump  = "http://www.roblox.com/asset/?id=910016857",
			fall  = "http://www.roblox.com/asset/?id=910001910"
		}},
		{name = "Cartoony", ids = {
			idle1 = "http://www.roblox.com/asset/?id=742637544",
			idle2 = "http://www.roblox.com/asset/?id=742638445",
			walk  = "http://www.roblox.com/asset/?id=742640026",
			run   = "http://www.roblox.com/asset/?id=742638842",
			jump  = "http://www.roblox.com/asset/?id=742637942",
			fall  = "http://www.roblox.com/asset/?id=742637151"
		}},
		{name = "Elder", ids = {
			idle1 = "http://www.roblox.com/asset/?id=845397899",
			idle2 = "http://www.roblox.com/asset/?id=845400520",
			walk  = "http://www.roblox.com/asset/?id=845403856",
			run   = "http://www.roblox.com/asset/?id=845386501",
			jump  = "http://www.roblox.com/asset/?id=845398858",
			fall  = "http://www.roblox.com/asset/?id=845396048"
		}},
		{name = "Knight", ids = {
			idle1 = "http://www.roblox.com/asset/?id=657595757",
			idle2 = "http://www.roblox.com/asset/?id=657568135",
			walk  = "http://www.roblox.com/asset/?id=657552124",
			run   = "http://www.roblox.com/asset/?id=657564596",
			jump  = "http://www.roblox.com/asset/?id=658409194",
			fall  = "http://www.roblox.com/asset/?id=657600338"
		}},
		{name = "Levitation", ids = {
			idle1 = "http://www.roblox.com/asset/?id=616006778",
			idle2 = "http://www.roblox.com/asset/?id=616008087",
			walk  = "http://www.roblox.com/asset/?id=616013216",
			run   = "http://www.roblox.com/asset/?id=616010382",
			jump  = "http://www.roblox.com/asset/?id=616008936",
			fall  = "http://www.roblox.com/asset/?id=616005863"
		}},
		{name = "Mage", ids = {
			idle1 = "http://www.roblox.com/asset/?id=707742142",
			idle2 = "http://www.roblox.com/asset/?id=707855907",
			walk  = "http://www.roblox.com/asset/?id=707897309",
			run   = "http://www.roblox.com/asset/?id=707861613",
			jump  = "http://www.roblox.com/asset/?id=707853694",
			fall  = "http://www.roblox.com/asset/?id=707829716"
		}},
		{name = "Ninja", ids = {
			idle1 = "http://www.roblox.com/asset/?id=656117400",
			idle2 = "http://www.roblox.com/asset/?id=656118341",
			walk  = "http://www.roblox.com/asset/?id=656121766",
			run   = "http://www.roblox.com/asset/?id=656118852",
			jump  = "http://www.roblox.com/asset/?id=656117878",
			fall  = "http://www.roblox.com/asset/?id=656115606"
		}},
		{name = "Pirate", ids = {
			idle1 = "http://www.roblox.com/asset/?id=750781874",
			idle2 = "http://www.roblox.com/asset/?id=750782770",
			walk  = "http://www.roblox.com/asset/?id=750785693",
			run   = "http://www.roblox.com/asset/?id=750783738",
			jump  = "http://www.roblox.com/asset/?id=750782230",
			fall  = "http://www.roblox.com/asset/?id=750780242"
		}},
		{name = "Robot", ids = {
			idle1 = "http://www.roblox.com/asset/?id=616088211",
			idle2 = "http://www.roblox.com/asset/?id=616089559",
			walk  = "http://www.roblox.com/asset/?id=616095330",
			run   = "http://www.roblox.com/asset/?id=616091570",
			jump  = "http://www.roblox.com/asset/?id=616090535",
			fall  = "http://www.roblox.com/asset/?id=616087089"
		}},
		{name = "Stylish", ids = {
			idle1 = "http://www.roblox.com/asset/?id=616136790",
			idle2 = "http://www.roblox.com/asset/?id=616138447",
			walk  = "http://www.roblox.com/asset/?id=616146177",
			run   = "http://www.roblox.com/asset/?id=616140816",
			jump  = "http://www.roblox.com/asset/?id=616139451",
			fall  = "http://www.roblox.com/asset/?id=616134815"
		}},
		{name = "SuperHero", ids = {
			idle1 = "http://www.roblox.com/asset/?id=616111295",
			idle2 = "http://www.roblox.com/asset/?id=616113536",
			walk  = "http://www.roblox.com/asset/?id=616122287",
			run   = "http://www.roblox.com/asset/?id=616117076",
			jump  = "http://www.roblox.com/asset/?id=616115533",
			fall  = "http://www.roblox.com/asset/?id=616108001"
		}},
		{name = "Toy", ids = {
			idle1 = "http://www.roblox.com/asset/?id=782841498",
			idle2 = "http://www.roblox.com/asset/?id=782845736",
			walk  = "http://www.roblox.com/asset/?id=782843345",
			run   = "http://www.roblox.com/asset/?id=782842708",
			jump  = "http://www.roblox.com/asset/?id=782847020",
			fall  = "http://www.roblox.com/asset/?id=782846423"
		}},
		{name = "Vampire", ids = {
			idle1 = "http://www.roblox.com/asset/?id=1083445855",
			idle2 = "http://www.roblox.com/asset/?id=1083450166",
			walk  = "http://www.roblox.com/asset/?id=1083473930",
			run   = "http://www.roblox.com/asset/?id=1083462077",
			jump  = "http://www.roblox.com/asset/?id=1083455352",
			fall  = "http://www.roblox.com/asset/?id=1083443587"
		}},
		{name = "Werewolf", ids = {
			idle1 = "http://www.roblox.com/asset/?id=1083195517",
			idle2 = "http://www.roblox.com/asset/?id=1083214717",
			walk  = "http://www.roblox.com/asset/?id=1083178339",
			run   = "http://www.roblox.com/asset/?id=1083216690",
			jump  = "http://www.roblox.com/asset/?id=1083218792",
			fall  = "http://www.roblox.com/asset/?id=1083189019"
		}},
		{name = "Zombie", ids = {
			idle1 = "http://www.roblox.com/asset/?id=616158929",
			idle2 = "http://www.roblox.com/asset/?id=616160636",
			walk  = "http://www.roblox.com/asset/?id=616168032",
			run   = "http://www.roblox.com/asset/?id=616163682",
			jump  = "http://www.roblox.com/asset/?id=616161997",
			fall  = "http://www.roblox.com/asset/?id=616157476"
		}},
		{name = "Patrol", ids = {
			idle1 = "http://www.roblox.com/asset/?id=1149612882",
			idle2 = "http://www.roblox.com/asset/?id=1150842221",
			walk  = "http://www.roblox.com/asset/?id=1151231493",
			run   = "http://www.roblox.com/asset/?id=1150967949",
			jump  = "http://www.roblox.com/asset/?id=1148811837",
			fall  = "http://www.roblox.com/asset/?id=1148863382"
		}},
		{name = "Confident", ids = {
			idle1 = "http://www.roblox.com/asset/?id=1069977950",
			idle2 = "http://www.roblox.com/asset/?id=1069987858",
			walk  = "http://www.roblox.com/asset/?id=1070017263",
			run   = "http://www.roblox.com/asset/?id=1070001516",
			jump  = "http://www.roblox.com/asset/?id=1069984524",
			fall  = "http://www.roblox.com/asset/?id=1069973677"
		}},
		{name = "Popstar", ids = {
			idle1 = "http://www.roblox.com/asset/?id=1212900985",
			idle2 = "http://www.roblox.com/asset/?id=1150842221",
			walk  = "http://www.roblox.com/asset/?id=1212980338",
			run   = "http://www.roblox.com/asset/?id=1212980348",
			jump  = "http://www.roblox.com/asset/?id=1212954642",
			fall  = "http://www.roblox.com/asset/?id=1212900995"
		}},
		{name = "Cowboy", ids = {
			idle1 = "http://www.roblox.com/asset/?id=1014390418",
			idle2 = "http://www.roblox.com/asset/?id=1014398616",
			walk  = "http://www.roblox.com/asset/?id=1014421541",
			run   = "http://www.roblox.com/asset/?id=1014401683",
			jump  = "http://www.roblox.com/asset/?id=1014394726",
			fall  = "http://www.roblox.com/asset/?id=1014384571"
		}},
		{name = "Ghost", ids = {
			idle1 = "http://www.roblox.com/asset/?id=616006778",
			idle2 = "http://www.roblox.com/asset/?id=616008087",
			walk  = "http://www.roblox.com/asset/?id=616013216",
			run   = "http://www.roblox.com/asset/?id=616010382",
			jump  = "http://www.roblox.com/asset/?id=616008936",
			fall  = "http://www.roblox.com/asset/?id=616005863"
		}},
		{name = "Sneaky", ids = {
			idle1 = "http://www.roblox.com/asset/?id=1132473842",
			idle2 = "http://www.roblox.com/asset/?id=1132477671",
			walk  = "http://www.roblox.com/asset/?id=1132510133",
			run   = "http://www.roblox.com/asset/?id=1132494274",
			jump  = "http://www.roblox.com/asset/?id=1132489853",
			fall  = "http://www.roblox.com/asset/?id=1132469004"
		}},
		{name = "Princess", ids = {
			idle1 = "http://www.roblox.com/asset/?id=941003647",
			idle2 = "http://www.roblox.com/asset/?id=941013098",
			walk  = "http://www.roblox.com/asset/?id=941028902",
			run   = "http://www.roblox.com/asset/?id=941015281",
			jump  = "http://www.roblox.com/asset/?id=941008832",
			fall  = "http://www.roblox.com/asset/?id=941000007"
		}},
		{name = "None", ids = {
			idle1 = "http://www.roblox.com/asset/?id=0",
			idle2 = "http://www.roblox.com/asset/?id=0",
			walk  = "http://www.roblox.com/asset/?id=0",
			run   = "http://www.roblox.com/asset/?id=0",
			jump  = "http://www.roblox.com/asset/?id=0",
			fall  = "http://www.roblox.com/asset/?id=0"
		}},
		{name = "Anthro (Default)", ids = {
			idle1 = "http://www.roblox.com/asset/?id=2510196951",
			idle2 = "http://www.roblox.com/asset/?id=2510197257",
			walk  = "http://www.roblox.com/asset/?id=2510202577",
			run   = "http://www.roblox.com/asset/?id=2510198475",
			jump  = "http://www.roblox.com/asset/?id=2510197830",
			fall  = "http://www.roblox.com/asset/?id=2510195892"
		}},
	}

	for _, anim in ipairs(anims) do
		CreateAnimButton(anim.name, anim.ids)
	end

	AnimToggleBtn.MouseButton1Click:Connect(function()
		animState.enabled = not animState.enabled
		if animState.enabled then
			animSelected = {}
			TweenService:Create(AnimToggleBtn, TweenInfo.new(0.25), {BackgroundColor3 = C_ACCENT}):Play()
			TweenService:Create(ToggleKnob, TweenInfo.new(0.25, Enum.EasingStyle.Back), {
				Position = UDim2.new(1, -25, 0.5, -11)
			}):Play()
			AnimListContainer.Visible = true
		else
			TweenService:Create(AnimToggleBtn, TweenInfo.new(0.25), {BackgroundColor3 = Color3.fromRGB(40, 44, 56)}):Play()
			TweenService:Create(ToggleKnob, TweenInfo.new(0.25, Enum.EasingStyle.Back), {
				Position = UDim2.new(0, 3, 0.5, -11)
			}):Play()
			AnimListContainer.Visible = false
			animSelected = {}
			local char = Player.Character
			if char then
				local animate = char:FindFirstChild("Animate")
				if animate then
					animate.Enabled = false
					task.wait(0.05)
					animate.Enabled = true
				end
			end
		end
	end)

	local SilentPanel = Instance.new("ScrollingFrame")
	SilentPanel.Size = UDim2.new(1, 0, 1, 0)
	SilentPanel.BackgroundTransparency = 1
	SilentPanel.BorderSizePixel = 0
	SilentPanel.ScrollBarThickness = 2
	SilentPanel.ScrollBarImageColor3 = C_ACCENT
	SilentPanel.ScrollBarImageTransparency = 0.5
	SilentPanel.CanvasSize = UDim2.new(0, 0, 0, 0)
	SilentPanel.AutomaticCanvasSize = Enum.AutomaticSize.Y
	SilentPanel.Visible = false
	SilentPanel.ZIndex = 1
	SilentPanel.Parent = ContentHolder

	local SilentLayout = Instance.new("UIListLayout")
	SilentLayout.Padding = UDim.new(0, 8)
	SilentLayout.SortOrder = Enum.SortOrder.LayoutOrder
	SilentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	SilentLayout.Parent = SilentPanel

	local SilentPad = Instance.new("UIPadding")
	SilentPad.PaddingTop = UDim.new(0, 10)
	SilentPad.PaddingBottom = UDim.new(0, 10)
	SilentPad.PaddingLeft = UDim.new(0, 10)
	SilentPad.PaddingRight = UDim.new(0, 10)
	SilentPad.Parent = SilentPanel

	local function CreateToggleRow(parent, title, subtitle, layoutOrder, default)
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -20, 0, 50)
		row.BackgroundColor3 = C_BOX
		row.BackgroundTransparency = 0.15
		row.BorderSizePixel = 0
		row.LayoutOrder = layoutOrder or 0
		row.Parent = parent

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 10)
		corner.Parent = row

		local stroke = Instance.new("UIStroke")
		stroke.Color = C_DIVIDER
		stroke.Thickness = 1
		stroke.Transparency = 0.4
		stroke.Parent = row

		local t = Instance.new("TextLabel")
		t.Size = UDim2.new(1, -80, 0, 20)
		t.Position = UDim2.new(0, 16, 0, 8)
		t.BackgroundTransparency = 1
		t.Text = title
		t.TextColor3 = C_TEXT
		t.TextSize = 13
		t.Font = Enum.Font.GothamBold
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.Parent = row

		local s = Instance.new("TextLabel")
		s.Size = UDim2.new(1, -80, 0, 14)
		s.Position = UDim2.new(0, 16, 0, 28)
		s.BackgroundTransparency = 1
		s.Text = subtitle or ""
		s.TextColor3 = C_TEXT_DIM
		s.TextSize = 10
		s.Font = Enum.Font.Gotham
		s.TextXAlignment = Enum.TextXAlignment.Left
		s.Parent = row

		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(0, 52, 0, 28)
		btn.Position = UDim2.new(1, -68, 0.5, -14)
		btn.BackgroundColor3 = default and C_ACCENT or Color3.fromRGB(40, 44, 56)
		btn.BorderSizePixel = 0
		btn.Text = ""
		btn.AutoButtonColor = false
		btn.Parent = row

		local btnCorner = Instance.new("UICorner")
		btnCorner.CornerRadius = UDim.new(1, 0)
		btnCorner.Parent = btn

		local knob = Instance.new("Frame")
		knob.Size = UDim2.new(0, 22, 0, 22)
		knob.Position = default and UDim2.new(1, -25, 0.5, -11) or UDim2.new(0, 3, 0.5, -11)
		knob.BackgroundColor3 = Color3.fromRGB(180, 185, 200)
		knob.BorderSizePixel = 0
		knob.Parent = btn

		local knobCorner = Instance.new("UICorner")
		knobCorner.CornerRadius = UDim.new(1, 0)
		knobCorner.Parent = knob

		return btn, knob, row
	end

	local function CreateSliderRow(parent, title, subtitle, layoutOrder, minV, maxV, defaultV, callback)
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -20, 0, 60)
		row.BackgroundColor3 = C_BOX
		row.BackgroundTransparency = 0.15
		row.BorderSizePixel = 0
		row.LayoutOrder = layoutOrder or 0
		row.Parent = parent

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 10)
		corner.Parent = row

		local stroke = Instance.new("UIStroke")
		stroke.Color = C_DIVIDER
		stroke.Thickness = 1
		stroke.Transparency = 0.4
		stroke.Parent = row

		local t = Instance.new("TextLabel")
		t.Size = UDim2.new(1, -80, 0, 18)
		t.Position = UDim2.new(0, 16, 0, 6)
		t.BackgroundTransparency = 1
		t.Text = title
		t.TextColor3 = C_TEXT
		t.TextSize = 12
		t.Font = Enum.Font.GothamBold
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.Parent = row

		local s = Instance.new("TextLabel")
		s.Size = UDim2.new(1, -80, 0, 12)
		s.Position = UDim2.new(0, 16, 0, 22)
		s.BackgroundTransparency = 1
		s.Text = subtitle or ""
		s.TextColor3 = C_TEXT_DIM
		s.TextSize = 9
		s.Font = Enum.Font.Gotham
		s.TextXAlignment = Enum.TextXAlignment.Left
		s.Parent = row

		local valueLabel = Instance.new("TextLabel")
		valueLabel.Size = UDim2.new(0, 60, 0, 18)
		valueLabel.Position = UDim2.new(1, -76, 0, 8)
		valueLabel.BackgroundTransparency = 1
		valueLabel.Text = tostring(defaultV)
		valueLabel.TextColor3 = C_ACCENT
		valueLabel.TextSize = 12
		valueLabel.Font = Enum.Font.GothamBold
		valueLabel.TextXAlignment = Enum.TextXAlignment.Right
		valueLabel.Parent = row

		local bar = Instance.new("Frame")
		bar.Size = UDim2.new(1, -32, 0, 8)
		bar.Position = UDim2.new(0, 16, 0, 42)
		bar.BackgroundColor3 = Color3.fromRGB(35, 38, 50)
		bar.BorderSizePixel = 0
		bar.Parent = row

		local barCorner = Instance.new("UICorner")
		barCorner.CornerRadius = UDim.new(1, 0)
		barCorner.Parent = bar

		local fill = Instance.new("Frame")
		fill.Size = UDim2.new((defaultV - minV) / (maxV - minV), 0, 1, 0)
		fill.BackgroundColor3 = C_ACCENT
		fill.BorderSizePixel = 0
		fill.Parent = bar

		local fillCorner = Instance.new("UICorner")
		fillCorner.CornerRadius = UDim.new(1, 0)
		fillCorner.Parent = fill

		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(1, 0, 1, 24)
		btn.Position = UDim2.new(0, 0, 0, -8)
		btn.BackgroundTransparency = 1
		btn.Text = ""
		btn.AutoButtonColor = false
		btn.Parent = row

		local dragging = false
		local function update(input)
			local pos = input.Position.X - bar.AbsolutePosition.X
			local alpha = math.clamp(pos / bar.AbsoluteSize.X, 0, 1)
			local val = minV + (maxV - minV) * alpha
			fill.Size = UDim2.new(alpha, 0, 1, 0)
			valueLabel.Text = tostring(math.floor(val * 10 + 0.5) / 10)
			if callback then callback(val) end
		end

		btn.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				update(input)
			end
		end)
		UserInputService.InputChanged:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				update(input)
			end
		end)
		UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end)

		return {
			Set = function(v)
				local alpha = (v - minV) / (maxV - minV)
				fill.Size = UDim2.new(alpha, 0, 1, 0)
				valueLabel.Text = tostring(v)
				if callback then callback(v) end
			end
		}
	end

	local function CreateDropdownRow(parent, title, subtitle, layoutOrder, options, defaultOpt, callback)
		local selected = defaultOpt or options[1]
		local isOpen = false

		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -20, 0, 50)
		row.BackgroundColor3 = C_BOX
		row.BackgroundTransparency = 0.15
		row.BorderSizePixel = 0
		row.LayoutOrder = layoutOrder or 0
		row.ClipsDescendants = false
		row.ZIndex = 3
		row.Parent = parent

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 10)
		corner.Parent = row

		local stroke = Instance.new("UIStroke")
		stroke.Color = C_DIVIDER
		stroke.Thickness = 1
		stroke.Transparency = 0.4
		stroke.Parent = row

		local t = Instance.new("TextLabel")
		t.Size = UDim2.new(1, -120, 0, 20)
		t.Position = UDim2.new(0, 16, 0, 8)
		t.BackgroundTransparency = 1
		t.Text = title
		t.TextColor3 = C_TEXT
		t.TextSize = 13
		t.Font = Enum.Font.GothamBold
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.ZIndex = 4
		t.Parent = row

		local s = Instance.new("TextLabel")
		s.Size = UDim2.new(1, -120, 0, 14)
		s.Position = UDim2.new(0, 16, 0, 28)
		s.BackgroundTransparency = 1
		s.Text = subtitle or ""
		s.TextColor3 = C_TEXT_DIM
		s.TextSize = 10
		s.Font = Enum.Font.Gotham
		s.TextXAlignment = Enum.TextXAlignment.Left
		s.ZIndex = 4
		s.Parent = row

		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(0, 100, 0, 28)
		btn.Position = UDim2.new(1, -116, 0.5, -14)
		btn.BackgroundColor3 = Color3.fromRGB(40, 44, 56)
		btn.BorderSizePixel = 0
		btn.Text = tostring(selected)
		btn.TextColor3 = C_TEXT
		btn.TextSize = 11
		btn.Font = Enum.Font.GothamBold
		btn.AutoButtonColor = false
		btn.ZIndex = 4
		btn.Parent = row

		local btnCorner = Instance.new("UICorner")
		btnCorner.CornerRadius = UDim.new(0, 6)
		btnCorner.Parent = btn

		local list = Instance.new("Frame")
		list.Size = UDim2.new(0, 140, 0, #options * 24 + 8)
		list.Position = UDim2.new(1, -116, 0, 48)
		list.BackgroundColor3 = Color3.fromRGB(22, 24, 34)
		list.BorderSizePixel = 0
		list.Visible = false
		list.ZIndex = 20
		list.Parent = row

		local listCorner = Instance.new("UICorner")
		listCorner.CornerRadius = UDim.new(0, 6)
		listCorner.Parent = list

		local listStroke = Instance.new("UIStroke")
		listStroke.Color = C_ACCENT
		listStroke.Thickness = 1
		listStroke.Transparency = 0.2
		listStroke.Parent = list

		local listPad = Instance.new("UIPadding")
		listPad.PaddingTop = UDim.new(0, 4)
		listPad.PaddingBottom = UDim.new(0, 4)
		listPad.Parent = list

		local listLayout = Instance.new("UIListLayout")
		listLayout.Padding = UDim.new(0, 2)
		listLayout.Parent = list

		for i, opt in ipairs(options) do
			local optBtn = Instance.new("TextButton")
			optBtn.Size = UDim2.new(1, -8, 0, 22)
			optBtn.BackgroundTransparency = 1
			optBtn.Text = tostring(opt)
			optBtn.TextColor3 = C_TEXT_DIM
			optBtn.TextSize = 11
			optBtn.Font = Enum.Font.Gotham
			optBtn.TextXAlignment = Enum.TextXAlignment.Left
			optBtn.AutoButtonColor = false
			optBtn.LayoutOrder = i
			optBtn.ZIndex = 21
			optBtn.Parent = list

			local pad = Instance.new("UIPadding")
			pad.PaddingLeft = UDim.new(0, 8)
			pad.Parent = optBtn

			optBtn.MouseEnter:Connect(function()
				optBtn.TextColor3 = C_TEXT
				optBtn.BackgroundTransparency = 0.85
			end)
			optBtn.MouseLeave:Connect(function()
				optBtn.TextColor3 = C_TEXT_DIM
				optBtn.BackgroundTransparency = 1
			end)
			optBtn.MouseButton1Click:Connect(function()
				selected = opt
				btn.Text = tostring(opt)
				list.Visible = false
				isOpen = false
				if callback then callback(opt) end
			end)
		end

		btn.MouseButton1Click:Connect(function()
			isOpen = not isOpen
			list.Visible = isOpen
		end)

		return {
			Set = function(v)
				selected = v
				btn.Text = tostring(v)
				if callback then callback(v) end
			end
		}
	end

	local function CreateColorPickerRow(parent, title, subtitle, layoutOrder, defaultColor, callback)
		local R, G, B = defaultColor.R, defaultColor.G, defaultColor.B

		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -20, 0, 90)
		row.BackgroundColor3 = C_BOX
		row.BackgroundTransparency = 0.15
		row.BorderSizePixel = 0
		row.LayoutOrder = layoutOrder or 0
		row.Parent = parent

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 10)
		corner.Parent = row

		local stroke = Instance.new("UIStroke")
		stroke.Color = C_DIVIDER
		stroke.Thickness = 1
		stroke.Transparency = 0.4
		stroke.Parent = row

		local t = Instance.new("TextLabel")
		t.Size = UDim2.new(1, -80, 0, 16)
		t.Position = UDim2.new(0, 16, 0, 6)
		t.BackgroundTransparency = 1
		t.Text = title
		t.TextColor3 = C_TEXT
		t.TextSize = 12
		t.Font = Enum.Font.GothamBold
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.Parent = row

		local s = Instance.new("TextLabel")
		s.Size = UDim2.new(1, -80, 0, 12)
		s.Position = UDim2.new(0, 16, 0, 22)
		s.BackgroundTransparency = 1
		s.Text = subtitle or ""
		s.TextColor3 = C_TEXT_DIM
		s.TextSize = 9
		s.Font = Enum.Font.Gotham
		s.TextXAlignment = Enum.TextXAlignment.Left
		s.Parent = row

		local preview = Instance.new("Frame")
		preview.Size = UDim2.new(0, 30, 0, 30)
		preview.Position = UDim2.new(1, -46, 0, 10)
		preview.BackgroundColor3 = defaultColor
		preview.BorderSizePixel = 0
		preview.Parent = row

		local prevCorner = Instance.new("UICorner")
		prevCorner.CornerRadius = UDim.new(0, 6)
		prevCorner.Parent = preview

		local prevStroke = Instance.new("UIStroke")
		prevStroke.Color = Color3.fromRGB(255, 255, 255)
		prevStroke.Thickness = 1
		prevStroke.Transparency = 0.5
		prevStroke.Parent = preview

		local function fire()
			local c = Color3.new(R, G, B)
			preview.BackgroundColor3 = c
			if callback then callback(c) end
		end

		local function makeRGBSlider(yOffset, label, ch, initial)
			local lbl = Instance.new("TextLabel")
			lbl.Size = UDim2.new(0, 14, 0, 14)
			lbl.Position = UDim2.new(0, 16, 0, yOffset)
			lbl.BackgroundTransparency = 1
			lbl.Text = label
			lbl.TextColor3 = C_TEXT_DIM
			lbl.TextSize = 11
			lbl.Font = Enum.Font.GothamBold
			lbl.Parent = row

			local bar = Instance.new("Frame")
			bar.Size = UDim2.new(1, -80, 0, 8)
			bar.Position = UDim2.new(0, 36, 0, yOffset + 3)
			bar.BackgroundColor3 = Color3.fromRGB(35, 38, 50)
			bar.BorderSizePixel = 0
			bar.Parent = row

			local barCorner = Instance.new("UICorner")
			barCorner.CornerRadius = UDim.new(1, 0)
			barCorner.Parent = bar

			local fill = Instance.new("Frame")
			fill.Size = UDim2.new(initial, 0, 1, 0)
			fill.BackgroundColor3 = C_ACCENT
			fill.BorderSizePixel = 0
			fill.Parent = bar

			local fillCorner = Instance.new("UICorner")
			fillCorner.CornerRadius = UDim.new(1, 0)
			fillCorner.Parent = fill

			local btn = Instance.new("TextButton")
			btn.Size = UDim2.new(1, 0, 1, 20)
			btn.Position = UDim2.new(0, 0, 0, -6)
			btn.BackgroundTransparency = 1
			btn.Text = ""
			btn.AutoButtonColor = false
			btn.Parent = row

			local dragging = false
			local function update(input)
				local pos = input.Position.X - bar.AbsolutePosition.X
				local alpha = math.clamp(pos / bar.AbsoluteSize.X, 0, 1)
				fill.Size = UDim2.new(alpha, 0, 1, 0)
				if ch == "R" then R = alpha elseif ch == "G" then G = alpha else B = alpha end
				fire()
			end
			btn.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
					dragging = true
					update(input)
				end
			end)
			UserInputService.InputChanged:Connect(function(input)
				if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
					update(input)
				end
			end)
			UserInputService.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
					dragging = false
				end
			end)
		end

		makeRGBSlider(44, "R", "R", R)
		makeRGBSlider(58, "G", "G", G)
		makeRGBSlider(72, "B", "B", B)

		return {
			Set = function(c)
				R, G, B = c.R, c.G, c.B
				fire()
			end
		}
	end

	local autoShootEnabled = false
	local autoShootAgresivoEnabled = false
	local autoShootTargetPart = "Cabeza"
	local silentAimManualEnabled = false
	local silentAimFovEnabled = false
	local silentAimTargetPart = "Cabeza"
	local fovVisiblePreference = false
	local fovRadius = 120
	local equipGunEnabled = false
	local espEnabled = false
	local espColor = Color3.fromRGB(255, 255, 255)
	local espGlow = true

	getgenv().RoxHubTargetPart = nil

	local function refreshMonitor()
		if autoShootEnabled or autoShootAgresivoEnabled or silentAimManualEnabled
			or silentAimFovEnabled or equipGunEnabled or espEnabled then
			startTargetMonitor()
		else
			stopTargetMonitor()
		end
	end

	local asBtn, asKnob = CreateToggleRow(SilentPanel, "AUTO SHOOT NORMAL", "APUNTA AL ENEMIGO MÁS CERCANO, SIN FALLAR", 0, false)
	asBtn.MouseButton1Click:Connect(function()
		autoShootEnabled = not autoShootEnabled
		TweenService:Create(asBtn, TweenInfo.new(0.25), {BackgroundColor3 = autoShootEnabled and C_ACCENT or Color3.fromRGB(40, 44, 56)}):Play()
		TweenService:Create(asKnob, TweenInfo.new(0.25, Enum.EasingStyle.Back), {
			Position = autoShootEnabled and UDim2.new(1, -25, 0.5, -11) or UDim2.new(0, 3, 0.5, -11)
		}):Play()
		refreshMonitor()
	end)

	local asaBtn, asaKnob = CreateToggleRow(SilentPanel, "AUTO SHOOT AGRESIVO", "APUNTA AL ENEMIGO USANDO DIFERENTES PARTES", 1, false)
	asaBtn.MouseButton1Click:Connect(function()
		autoShootAgresivoEnabled = not autoShootAgresivoEnabled
		TweenService:Create(asaBtn, TweenInfo.new(0.25), {BackgroundColor3 = autoShootAgresivoEnabled and C_ACCENT or Color3.fromRGB(40, 44, 56)}):Play()
		TweenService:Create(asaKnob, TweenInfo.new(0.25, Enum.EasingStyle.Back), {
			Position = autoShootAgresivoEnabled and UDim2.new(1, -25, 0.5, -11) or UDim2.new(0, 3, 0.5, -11)
		}):Play()
		refreshMonitor()
	end)

	CreateDropdownRow(SilentPanel, "TARGET PARTE DEL CUERPO", "ELIGE DÓNDE APUNTAR", 2,
		{ "CABEZA", "TORSO", "CUERPO COMPLETO" }, "CABEZA",
		function(v) autoShootTargetPart = v; silentAimTargetPart = v end)

	local eqBtn, eqKnob = CreateToggleRow(SilentPanel, "EQUIPA LA ARMA AUTOMÁTICAMENTE", "EQUIPA LA PISTOLA CUANDO VE UN ENEMIGO", 3, false)
	eqBtn.MouseButton1Click:Connect(function()
		equipGunEnabled = not equipGunEnabled
		TweenService:Create(eqBtn, TweenInfo.new(0.25), {BackgroundColor3 = equipGunEnabled and C_ACCENT or Color3.fromRGB(40, 44, 56)}):Play()
		TweenService:Create(eqKnob, TweenInfo.new(0.25, Enum.EasingStyle.Back), {
			Position = equipGunEnabled and UDim2.new(1, -25, 0.5, -11) or UDim2.new(0, 3, 0.5, -11)
		}):Play()
		refreshMonitor()
	end)

	local samBtn, samKnob = CreateToggleRow(SilentPanel, "SILENT AIM", "REDIRIGE LAS BALAS AL ENEMIGO MÁS CERCANO", 4, false)
	samBtn.MouseButton1Click:Connect(function()
		silentAimManualEnabled = not silentAimManualEnabled
		TweenService:Create(samBtn, TweenInfo.new(0.25), {BackgroundColor3 = silentAimManualEnabled and C_ACCENT or Color3.fromRGB(40, 44, 56)}):Play()
		TweenService:Create(samKnob, TweenInfo.new(0.25, Enum.EasingStyle.Back), {
			Position = silentAimManualEnabled and UDim2.new(1, -25, 0.5, -11) or UDim2.new(0, 3, 0.5, -11)
		}):Play()
		refreshMonitor()
	end)

	local safBtn, safKnob = CreateToggleRow(SilentPanel, "SILENT AIM (CON FOV)", "SOLO APUNTA AL ENEMIGO DENTRO DEL CÍRCULO", 5, false)
	safBtn.MouseButton1Click:Connect(function()
		silentAimFovEnabled = not silentAimFovEnabled
		TweenService:Create(safBtn, TweenInfo.new(0.25), {BackgroundColor3 = silentAimFovEnabled and C_ACCENT or Color3.fromRGB(40, 44, 56)}):Play()
		TweenService:Create(safKnob, TweenInfo.new(0.25, Enum.EasingStyle.Back), {
			Position = silentAimFovEnabled and UDim2.new(1, -25, 0.5, -11) or UDim2.new(0, 3, 0.5, -11)
		}):Play()
		refreshMonitor()
	end)

	local sfvBtn, sfvKnob = CreateToggleRow(SilentPanel, "MOSTRAR FOV", "DIBUJA EL CÍRCULO EN LA PANTALLA", 6, false)
	sfvBtn.MouseButton1Click:Connect(function()
		fovVisiblePreference = not fovVisiblePreference
		TweenService:Create(sfvBtn, TweenInfo.new(0.25), {BackgroundColor3 = fovVisiblePreference and C_ACCENT or Color3.fromRGB(40, 44, 56)}):Play()
		TweenService:Create(sfvKnob, TweenInfo.new(0.25, Enum.EasingStyle.Back), {
			Position = fovVisiblePreference and UDim2.new(1, -25, 0.5, -11) or UDim2.new(0, 3, 0.5, -11)
		}):Play()
	end)

	CreateSliderRow(SilentPanel, "TAMAÑO DEL FOV", "MÁXIMO 0 - 200", 7, 10, 200, 120,
		function(v) fovRadius = v end)

	local VisualesPanel = Instance.new("ScrollingFrame")
	VisualesPanel.Size = UDim2.new(1, 0, 1, 0)
	VisualesPanel.BackgroundTransparency = 1
	VisualesPanel.BorderSizePixel = 0
	VisualesPanel.ScrollBarThickness = 2
	VisualesPanel.ScrollBarImageColor3 = C_ACCENT
	VisualesPanel.ScrollBarImageTransparency = 0.5
	VisualesPanel.CanvasSize = UDim2.new(0, 0, 0, 0)
	VisualesPanel.AutomaticCanvasSize = Enum.AutomaticSize.Y
	VisualesPanel.Visible = false
	VisualesPanel.ZIndex = 1
	VisualesPanel.Parent = ContentHolder

	local VisLayout = Instance.new("UIListLayout")
	VisLayout.Padding = UDim.new(0, 8)
	VisLayout.SortOrder = Enum.SortOrder.LayoutOrder
	VisLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	VisLayout.Parent = VisualesPanel

	local VisPad = Instance.new("UIPadding")
	VisPad.PaddingTop = UDim.new(0, 10)
	VisPad.PaddingBottom = UDim.new(0, 10)
	VisPad.PaddingLeft = UDim.new(0, 10)
	VisPad.PaddingRight = UDim.new(0, 10)
	VisPad.Parent = VisualesPanel

	local espFolder = Instance.new("Folder")
	espFolder.Name = "01ROXHUB"
	espFolder.Parent = ScreenGui

	local espBtn, espKnob = CreateToggleRow(VisualesPanel, "ESP HIGHLIGHT", "RESALTA A LOS ENEMIGOS CON ESP HIGHLIGHT", 0, false)
	espBtn.MouseButton1Click:Connect(function()
		espEnabled = not espEnabled
		TweenService:Create(espBtn, TweenInfo.new(0.25), {BackgroundColor3 = espEnabled and C_ACCENT or Color3.fromRGB(40, 44, 56)}):Play()
		TweenService:Create(espKnob, TweenInfo.new(0.25, Enum.EasingStyle.Back), {
			Position = espEnabled and UDim2.new(1, -25, 0.5, -11) or UDim2.new(0, 3, 0.5, -11)
		}):Play()
		refreshMonitor()
	end)

	CreateColorPickerRow(VisualesPanel, "COLOR DEL ESP", "ELIGE EL COLOR DEL ESP", 1,
		Color3.fromRGB(5, 5, 5), function(c) espColor = c end)

	local glowBtn, glowKnob = CreateToggleRow(VisualesPanel, "ACTIVAR ESP", "ACTIVAR TODAS LAS OPCIONES VISUALES", 2, true)
	TweenService:Create(glowBtn, TweenInfo.new(0.25), {BackgroundColor3 = C_ACCENT}):Play()
	TweenService:Create(glowKnob, TweenInfo.new(0.25, Enum.EasingStyle.Back), {
		Position = UDim2.new(1, -25, 0.5, -11)
	}):Play()
	glowBtn.MouseButton1Click:Connect(function()
		espGlow = not espGlow
		TweenService:Create(glowBtn, TweenInfo.new(0.25), {BackgroundColor3 = espGlow and C_ACCENT or Color3.fromRGB(40, 44, 56)}):Play()
		TweenService:Create(glowKnob, TweenInfo.new(0.25, Enum.EasingStyle.Back), {
			Position = espGlow and UDim2.new(1, -25, 0.5, -11) or UDim2.new(0, 3, 0.5, -11)
		}):Play()
	end)

	local activeESPs = {}
	local function cleanAllESPs()
		for p, hl in pairs(activeESPs) do
			if hl then hl:Destroy() end
			activeESPs[p] = nil
		end
	end
	Players.PlayerRemoving:Connect(function(p)
		if activeESPs[p] then
			activeESPs[p]:Destroy()
			activeESPs[p] = nil
		end
	end)
	task.spawn(function()
		while task.wait(0.2) do
			if espEnabled and IsInMatchStrict() then
				for _, p in ipairs(Players:GetPlayers()) do
					if p ~= Player and isEnemy(p) then
						local char = p.Character
						if char and char:FindFirstChild("Head") then
							local hl = activeESPs[p]
							if not hl or hl.Adornee ~= char or hl.Parent ~= espFolder then
								if hl then hl:Destroy() end
								hl = Instance.new("Highlight")
								hl.Name = "01ROXHUB" .. p.Name
								hl.FillTransparency = 0.5
								hl.OutlineTransparency = 1
								hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
								hl.Adornee = char
								hl.Parent = espFolder
								activeESPs[p] = hl
							end
							hl.Enabled = espGlow
							hl.FillColor = espColor
hl.OutlineColor = espColor
						elseif activeESPs[p] then
							activeESPs[p]:Destroy()
							activeESPs[p] = nil
						end
					elseif activeESPs[p] then
						activeESPs[p]:Destroy()
						activeESPs[p] = nil
					end
				end
			else
				cleanAllESPs()
			end
		end
	end)

	local MovePanel = Instance.new("ScrollingFrame")
	MovePanel.Size = UDim2.new(1, 0, 1, 0)
	MovePanel.BackgroundTransparency = 1
	MovePanel.BorderSizePixel = 0
	MovePanel.ScrollBarThickness = 2
	MovePanel.ScrollBarImageColor3 = C_ACCENT
	MovePanel.ScrollBarImageTransparency = 0.5
	MovePanel.CanvasSize = UDim2.new(0, 0, 0, 0)
	MovePanel.AutomaticCanvasSize = Enum.AutomaticSize.Y
	MovePanel.Visible = false
	MovePanel.ZIndex = 1
	MovePanel.Parent = ContentHolder

	local MoveLayout = Instance.new("UIListLayout")
	MoveLayout.Padding = UDim.new(0, 8)
	MoveLayout.SortOrder = Enum.SortOrder.LayoutOrder
	MoveLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	MoveLayout.Parent = MovePanel

	local MovePad = Instance.new("UIPadding")
	MovePad.PaddingTop = UDim.new(0, 10)
	MovePad.PaddingBottom = UDim.new(0, 10)
	MovePad.PaddingLeft = UDim.new(0, 10)
	MovePad.PaddingRight = UDim.new(0, 10)
	MovePad.Parent = MovePanel

	local PlatformActive = false
	local platformSpawned = false
	local activePlatforms = {}

	local function StartPlatforms()
		if platformSpawned then return end
		platformSpawned = true
		task.spawn(function()
			while PlatformActive do
				task.wait(0.05)
				local char = Player.Character
				if char and char:FindFirstChild("HumanoidRootPart") and char:FindFirstChild("Humanoid") then
					local hum = char.Humanoid
					if hum.MoveDirection.Magnitude > 0 or char.HumanoidRootPart.AssemblyLinearVelocity.Y ~= 0 then
						local platform = Instance.new("Part")
						platform.Size = Vector3.new(6, 0.6, 6)
						platform.Anchored = true
						platform.CanCollide = true
						platform.Color = Color3.fromRGB(5, 5, 5)
						platform.Material = Enum.Material.Neon
						platform.CFrame = char.HumanoidRootPart.CFrame * CFrame.new(0, -3.3, 0)
						platform.Parent = workspace

						table.insert(activePlatforms, platform)
						if #activePlatforms > 3 then
							local oldPlatform = table.remove(activePlatforms, 1)
							if oldPlatform then oldPlatform:Destroy() end
						end
					end
				end
			end
		end)
	end

	local function StopPlatforms()
		PlatformActive = false
		platformSpawned = false
		for _, plat in ipairs(activePlatforms) do
			if plat then plat:Destroy() end
		end
		activePlatforms = {}
	end

	local platToggleBtn, platToggleKnob = CreateToggleRow(MovePanel, "FIXED PLATFORM", "GENERA UNA PLATAFORMA", 0, false)

	platToggleBtn.MouseButton1Click:Connect(function()
		PlatformActive = not PlatformActive
		if PlatformActive then
			TweenService:Create(platToggleBtn, TweenInfo.new(0.25), {BackgroundColor3 = C_ACCENT}):Play()
			TweenService:Create(platToggleKnob, TweenInfo.new(0.25, Enum.EasingStyle.Back), {
				Position = UDim2.new(1, -25, 0.5, -11)
			}):Play()
			StartPlatforms()
		else
			TweenService:Create(platToggleBtn, TweenInfo.new(0.25), {BackgroundColor3 = Color3.fromRGB(40, 44, 56)}):Play()
			TweenService:Create(platToggleKnob, TweenInfo.new(0.25, Enum.EasingStyle.Back), {
				Position = UDim2.new(0, 3, 0.5, -11)
			}):Play()
			StopPlatforms()
		end
	end)

	
	local AltoFarmPanel = Instance.new("ScrollingFrame")
	AltoFarmPanel.Size = UDim2.new(1, 0, 1, 0)
	AltoFarmPanel.BackgroundTransparency = 1
	AltoFarmPanel.BorderSizePixel = 0
	AltoFarmPanel.ScrollBarThickness = 2
	AltoFarmPanel.ScrollBarImageColor3 = C_ACCENT
	AltoFarmPanel.ScrollBarImageTransparency = 0.5
	AltoFarmPanel.CanvasSize = UDim2.new(0, 0, 0, 0)
	AltoFarmPanel.AutomaticCanvasSize = Enum.AutomaticSize.Y
	AltoFarmPanel.Visible = false
	AltoFarmPanel.ZIndex = 1
	AltoFarmPanel.Parent = ContentHolder

	local AltoFarmLayout = Instance.new("UIListLayout")
	AltoFarmLayout.Padding = UDim.new(0, 8)
	AltoFarmLayout.SortOrder = Enum.SortOrder.LayoutOrder
	AltoFarmLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	AltoFarmLayout.Parent = AltoFarmPanel

	local AltoFarmPad = Instance.new("UIPadding")
	AltoFarmPad.PaddingTop = UDim.new(0, 10)
	AltoFarmPad.PaddingBottom = UDim.new(0, 10)
	AltoFarmPad.PaddingLeft = UDim.new(0, 10)
	AltoFarmPad.PaddingRight = UDim.new(0, 10)
	AltoFarmPad.Parent = AltoFarmPanel

	
	local AltoKillsPanel = Instance.new("ScrollingFrame")
	AltoKillsPanel.Size = UDim2.new(1, 0, 1, 0)
	AltoKillsPanel.BackgroundTransparency = 1
	AltoKillsPanel.BorderSizePixel = 0
	AltoKillsPanel.ScrollBarThickness = 2
	AltoKillsPanel.ScrollBarImageColor3 = C_ACCENT
	AltoKillsPanel.ScrollBarImageTransparency = 0.5
	AltoKillsPanel.CanvasSize = UDim2.new(0, 0, 0, 0)
	AltoKillsPanel.AutomaticCanvasSize = Enum.AutomaticSize.Y
	AltoKillsPanel.Visible = false
	AltoKillsPanel.ZIndex = 1
	AltoKillsPanel.Parent = ContentHolder

	local AltoKillsLayout = Instance.new("UIListLayout")
	AltoKillsLayout.Padding = UDim.new(0, 8)
	AltoKillsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	AltoKillsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	AltoKillsLayout.Parent = AltoKillsPanel

	local AltoKillsPad = Instance.new("UIPadding")
	AltoKillsPad.PaddingTop = UDim.new(0, 10)
	AltoKillsPad.PaddingBottom = UDim.new(0, 10)
	AltoKillsPad.PaddingLeft = UDim.new(0, 10)
	AltoKillsPad.PaddingRight = UDim.new(0, 10)
	AltoKillsPad.Parent = AltoKillsPanel

	-- ============ CONTROLES ALTO FARM ============
	local farmBtn, farmKnob = CreateToggleRow(AltoFarmPanel, "AUTO FARM HALLOWEEN", "RECOGE LOS SPAWNABLES DEL EVENTO AUTOMÁTICAMENTE", 0, false)
	farmBtn.MouseButton1Click:Connect(function()
		getgenv().RoxHubAutoEventFarm = not getgenv().RoxHubAutoEventFarm
		TweenService:Create(farmBtn, TweenInfo.new(0.25), {BackgroundColor3 = getgenv().RoxHubAutoEventFarm and C_ACCENT or Color3.fromRGB(40, 44, 56)}):Play()
		TweenService:Create(farmKnob, TweenInfo.new(0.25, Enum.EasingStyle.Back), {
			Position = getgenv().RoxHubAutoEventFarm and UDim2.new(1, -25, 0.5, -11) or UDim2.new(0, 3, 0.5, -11)
		}):Play()
	end)

	
	local kaBtn, kaKnob = CreateToggleRow(AltoKillsPanel, "KILL ALL BY NEXVYR HUB", "FASE BETA - USA BAJO TU RESPONSABILIDAD", 0, false)
	kaBtn.MouseButton1Click:Connect(function()
		local activar = not RoxKillAllInstance.running
		TweenService:Create(kaBtn, TweenInfo.new(0.25), {BackgroundColor3 = activar and C_ACCENT or Color3.fromRGB(40, 44, 56)}):Play()
		TweenService:Create(kaKnob, TweenInfo.new(0.25, Enum.EasingStyle.Back), {
			Position = activar and UDim2.new(1, -25, 0.5, -11) or UDim2.new(0, 3, 0.5, -11)
		}):Play()
		if activar then RoxKillAllInstance:Start() else RoxKillAllInstance:Stop() end
	end)

	CreateSliderRow(AltoKillsPanel, "VIBRACIÓN", "VIBRACIÓN MIENTRAS SE ACERCA", 1, 0.0, 3.0, 0.8,
		function(v) KILLALL_JITTER_AMPLITUDE = v end)

	CreateSliderRow(AltoKillsPanel, "RADIO DE ACTIVACIÓN", "DISTANCIA A LA QUE SE ACTIVA", 2, 2.75, 9.0, 6.0,
		function(v) KILLALL_TRIGGER_RADIUS = v end)

	local tabs = {
		HOME        = HomePanel,
		AIMBOT      = SilentPanel,
		VISUALES    = VisualesPanel,
		MOVIMIENTO  = MovePanel,
		ANIMACIONES = AnimPanel,
		["ALTO FARM"]  = AltoFarmPanel,
		["ALTO KILLS"] = AltoKillsPanel,
		SETTINGS    = SettingsPanel,
	}

	local sideButtons = {}
	local activeButton = nil

	local function CreateSideButton(text, selected)
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(1, -12, 0, 34)
		btn.BackgroundColor3 = selected and C_ACCENT_SOFT or Color3.fromRGB(22, 25, 35)
		btn.BackgroundTransparency = selected and 0 or 0.25
		btn.BorderSizePixel = 0
		btn.Text = text
		btn.TextColor3 = selected and C_TEXT or C_TEXT_DIM
		btn.TextSize = 13
		btn.Font = Enum.Font.GothamBold
		btn.TextXAlignment = Enum.TextXAlignment.Center
		btn.AutoButtonColor = false
		btn.ZIndex = 2
		btn.Parent = SideMenu

		local btnCorner = Instance.new("UICorner")
		btnCorner.CornerRadius = UDim.new(0, 6)
		btnCorner.Parent = btn

		local accent = Instance.new("Frame")
		accent.Size = UDim2.new(0, 3, 0, selected and 18 or 0)
		accent.Position = UDim2.new(0, 0, 0.5, selected and -9 or 0)
		accent.BackgroundColor3 = C_ACCENT
		accent.BorderSizePixel = 0
		accent.ZIndex = 4
		accent.Parent = btn

		local accentCorner = Instance.new("UICorner")
		accentCorner.CornerRadius = UDim.new(1, 0)
		accentCorner.Parent = accent

		sideButtons[text] = {button = btn, accent = accent}

		btn.MouseEnter:Connect(function()
			if activeButton == btn then return end
			TweenService:Create(btn, TweenInfo.new(0.15), {
				BackgroundColor3 = Color3.fromRGB(30, 34, 48), TextColor3 = C_TEXT
			}):Play()
		end)
		btn.MouseLeave:Connect(function()
			if activeButton == btn then return end
			TweenService:Create(btn, TweenInfo.new(0.15), {
				BackgroundColor3 = Color3.fromRGB(22, 25, 35), TextColor3 = C_TEXT_DIM
			}):Play()
		end)

		btn.MouseButton1Click:Connect(function()
			for _, data in pairs(sideButtons) do
				TweenService:Create(data.button, TweenInfo.new(0.18), {
					BackgroundColor3 = Color3.fromRGB(22, 25, 35), TextColor3 = C_TEXT_DIM
				}):Play()
				TweenService:Create(data.accent, TweenInfo.new(0.18), {
					Size = UDim2.new(0, 3, 0, 0), Position = UDim2.new(0, 0, 0.5, 0)
				}):Play()
			end

			activeButton = btn
			TweenService:Create(btn, TweenInfo.new(0.18), {
				BackgroundColor3 = C_ACCENT_SOFT, TextColor3 = C_TEXT
			}):Play()
			TweenService:Create(accent, TweenInfo.new(0.18), {
				Size = UDim2.new(0, 3, 0, 18), Position = UDim2.new(0, 0, 0.5, -9)
			}):Play()

			for _, panel in pairs(tabs) do
				if panel then panel.Visible = false end
			end
			if tabs[text] then
				tabs[text].Visible = true
			end
		end)

		if selected then activeButton = btn end
		return btn
	end

	CreateSideButton("HOME", true)
	CreateSideButton("AIMBOT", false)
	CreateSideButton("VISUALES", false)
	CreateSideButton("MOVIMIENTO", false)
	CreateSideButton("ANIMACIONES", false)
	CreateSideButton("ALTO FARM", false)
	CreateSideButton("ALTO KILLS", false)
	CreateSideButton("SETTINGS", false)

	local function AnimateOpen()
		MainFrame.Size = UDim2.new(0, 530, 0, 320)
		MainFrame.BackgroundTransparency = 0.3
		TweenService:Create(MainFrame, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Size = UDim2.new(0, 560, 0, 340),
			BackgroundTransparency = 0
		}):Play()
	end

	MainButton.MouseButton1Click:Connect(function()
		MainFrame.Visible = not MainFrame.Visible
		if MainFrame.Visible then AnimateOpen() end
	end)

	CloseBtn.MouseButton1Click:Connect(function()
		MainFrame.Visible = false
	end)

	Player.CharacterAdded:Connect(function(char)
		local animate = char:WaitForChild("Animate", 5)
		if animate and animSelected and animSelected.idle1 then
			task.wait(0.2)
			ApplyAnims(animSelected)
		end
	end)

	local oldNamecall
	if hookmetamethod and getnamecallmethod and checkcaller then
		oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
			local method = getnamecallmethod()
			if not checkcaller() and getgenv().RoxHubTargetPart then
				if method == "Raycast" and self == workspace then
					local target = getgenv().RoxHubTargetPart
					if target and target.Parent then
						local origin, direction, p3 = ...
						if typeof(direction) == "Vector3" and direction.Magnitude > 20 then
							local camOrigin = workspace.CurrentCamera.CFrame.Position
							if (origin - camOrigin).Magnitude >= 1 then
								local newDir = (target.Position - origin).Unit * 5000
								return oldNamecall(self, origin, newDir, p3)
							end
						end
					else
						getgenv().RoxHubTargetPart = nil
					end
				end
			end
			return oldNamecall(self, ...)
		end)
	end

	task.spawn(function()
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		while task.wait(0.1) do
			if (autoShootEnabled or autoShootAgresivoEnabled) then
				if estaEnLobby() then
					getgenv().RoxHubTargetPart = nil
					continue
				end
				local char = Player.Character
				if not char or not char:FindFirstChild("HumanoidRootPart") then
					getgenv().RoxHubTargetPart = nil
					continue
				end
				local arma = char:FindFirstChildOfClass("Tool")
				if not arma or not esPistola(arma) then
					getgenv().RoxHubTargetPart = nil
					continue
				end
				local bestPart, bestDist = nil, math.huge
				local myPos = char.HumanoidRootPart.Position
				local headPos = char:FindFirstChild("Head") and char.Head.Position or myPos
				for _, p in ipairs(Players:GetPlayers()) do
					if p ~= Player and isEnemy(p) then
						local ec = p.Character
						if ec then
							local eHum = ec:FindFirstChildOfClass("Humanoid")
							if eHum and eHum.Health > 0 then
								params.FilterDescendantsInstances = { char, ec }
								local function try(part)
									if not part or not part:IsA("BasePart") then return end
									local d = (part.Position - myPos).Magnitude
									if d < bestDist then
										local dir = (part.Position - headPos)
										if not workspace:Raycast(headPos, dir, params) then
											bestDist = d
											bestPart = part
										end
									end
								end
								if autoShootAgresivoEnabled then
									for _, part in ipairs(ec:GetChildren()) do
										if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then try(part) end
									end
								else
									if autoShootTargetPart == "Cabeza" then
										try(ec:FindFirstChild("Head"))
									elseif autoShootTargetPart == "Torso" then
										try(ec:FindFirstChild("UpperTorso"))
										try(ec:FindFirstChild("Torso"))
										try(ec:FindFirstChild("HumanoidRootPart"))
									else
										for _, part in ipairs(ec:GetChildren()) do
											if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then try(part) end
										end
									end
								end
							end
						end
					end
				end
				if bestPart then
					getgenv().RoxHubTargetPart = bestPart
					pcall(function()
						arma:Activate()
						task.delay(0.05, function() if arma.Parent == char then arma:Deactivate() end end)
					end)
					task.wait(0.15)
				else
					getgenv().RoxHubTargetPart = nil
				end
			end
		end
	end)

	task.spawn(function()
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		while task.wait(0.1) do
			if (silentAimManualEnabled or silentAimFovEnabled) then
				if estaEnLobby() then
					if not autoShootEnabled and not autoShootAgresivoEnabled then
						getgenv().RoxHubTargetPart = nil
					end
					continue
				end
				local char = Player.Character
				if not char or not char:FindFirstChild("HumanoidRootPart") then continue end
				local bestPart, bestDistCenter, bestDistFis = nil, math.huge, math.huge
				local myPos = char.HumanoidRootPart.Position
				local headPos = char:FindFirstChild("Head") and char.Head.Position or myPos
				for _, p in ipairs(Players:GetPlayers()) do
					if p ~= Player and isEnemy(p) then
						local ec = p.Character
						if ec then
							local eHum = ec:FindFirstChildOfClass("Humanoid")
							if eHum and eHum.Health > 0 then
								local parts = {}
								if silentAimTargetPart == "Cabeza" then
									local h = ec:FindFirstChild("Head")
									if h then table.insert(parts, h) end
								elseif silentAimTargetPart == "Torso" then
									for _, n in ipairs({"UpperTorso","Torso","HumanoidRootPart"}) do
										local pp = ec:FindFirstChild(n)
										if pp then table.insert(parts, pp) end
									end
								else
									for _, part in ipairs(ec:GetChildren()) do
										if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then table.insert(parts, part) end
									end
								end
								params.FilterDescendantsInstances = { char, ec }
								for _, part in ipairs(parts) do
									local distFis = (part.Position - myPos).Magnitude
									local pos2D, onScreen = workspace.CurrentCamera:WorldToViewportPoint(part.Position)
									local distCenter = (Vector2.new(pos2D.X, pos2D.Y) - Vector2.new(workspace.CurrentCamera.ViewportSize.X/2, workspace.CurrentCamera.ViewportSize.Y/2)).Magnitude
									local pass = false
									if silentAimFovEnabled and onScreen and distCenter <= fovRadius and distCenter < bestDistCenter then
										pass = true
									elseif silentAimManualEnabled and distFis < bestDistFis then
										pass = true
									end
									if pass then
										if not workspace:Raycast(headPos, part.Position - headPos, params) then
											if silentAimFovEnabled then bestDistCenter = distCenter else bestDistFis = distFis end
											bestPart = part
										end
									end
								end
							end
						end
					end
				end
				if bestPart then
					getgenv().RoxHubTargetPart = bestPart
				else
					if not autoShootEnabled and not autoShootAgresivoEnabled then
						getgenv().RoxHubTargetPart = nil
					end
				end
			end
		end
	end)

	task.spawn(function()
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		while task.wait(0.15) do
			if not equipGunEnabled then continue end
			if not IsInMatchStrict() then continue end
			local char = Player.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if not char or not hum or hum.Health <= 0 then continue end
			local hrp = char:FindFirstChild("HumanoidRootPart")
			local head = char:FindFirstChild("Head")
			local origin = head and head.Position or (hrp and hrp.Position)
			if not origin then continue end
			local hay = false
			for _, p in ipairs(Players:GetPlayers()) do
				if p ~= Player and esEnemigoValido(p) then
					local ec = p.Character
					if ec then
						local tp = ec:FindFirstChild("Head") or ec:FindFirstChild("UpperTorso") or ec:FindFirstChild("HumanoidRootPart")
						if tp then
							params.FilterDescendantsInstances = { char, ec }
							if not workspace:Raycast(origin, tp.Position - origin, params) then
								hay = true; break
							end
						end
					end
				end
			end
			if not hay then continue end
			local pistola = obtenerPistola()
			if not pistola or pistola.Parent == char then continue end
			pcall(function() hum:EquipTool(pistola) end)
		end
	end)

	local FOVCircle = nil
	if Drawing then
		FOVCircle = Drawing.new("Circle")
		FOVCircle.Position = Vector2.new(workspace.CurrentCamera.ViewportSize.X/2, workspace.CurrentCamera.ViewportSize.Y/2)
		FOVCircle.Radius = fovRadius
		FOVCircle.Filled = false
		FOVCircle.Color = Color3.fromRGB(255, 255, 255)
		FOVCircle.Visible = false
		FOVCircle.Thickness = 1
	end

	RunService.RenderStepped:Connect(function()
		if fovVisiblePreference and FOVCircle then
			FOVCircle.Position = Vector2.new(workspace.CurrentCamera.ViewportSize.X/2, workspace.CurrentCamera.ViewportSize.Y/2)
			FOVCircle.Radius = fovRadius
			FOVCircle.Visible = true
			FOVCircle.Color = (silentAimFovEnabled and getgenv().RoxHubTargetPart) and Color3.fromRGB(0,255,0) or Color3.fromRGB(255,255,255)
		elseif FOVCircle then
			FOVCircle.Visible = false
		end
	end)
end

LoadHub()

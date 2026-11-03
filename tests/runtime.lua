-- Small Roblox test double: exercises the complete script, not real replication/physics.
local failures = {}
local function signal(reverse)
    local listeners = {}
    return {
        Connect = function(self, fn)
            local c = { Connected = true }
            function c:Disconnect() self.Connected = false end
            listeners[#listeners + 1] = { connection = c, fn = fn }
            return c
        end,
        Fire = function(self, ...)
            local copy = { table.unpack(listeners) }
            for i = 1, #copy do
                local entry = copy[reverse and (#copy - i + 1) or i]
                if entry.connection.Connected then entry.fn(...) end
            end
        end,
    }
end
local vectorMt = {}
local function v(x,y,z) return setmetatable({X=x,Y=y,Z=z}, vectorMt) end
vectorMt.__add = function(a,b) return v(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
vectorMt.__sub = function(a,b) return v(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
vectorMt.__mul = function(a,b) return v(a.X*b,a.Y*b,a.Z*b) end
vectorMt.__index = function(a,k)
    if k == 'Magnitude' then return math.sqrt(a.X*a.X+a.Y*a.Y+a.Z*a.Z) end
    if k == 'Dot' then return function(a,b) return a.X*b.X+a.Y*b.Y+a.Z*b.Z end end
end
Vector3 = { new=v, zero=v(0,0,0) }
Vector2 = { new=function(x,y) return {X=x,Y=y} end }
local cframeMt = {}
cframeMt.__mul = function(a,b) return setmetatable({Position=a.Position,Rotation=b}, cframeMt) end
cframeMt.__index = { Lerp=function(a,b,t)
    return setmetatable({Position=a.Position+(b.Position-a.Position)*t,Rotation=a.Rotation},cframeMt)
end }
CFrame = { new=function(p) return setmetatable({Position=p,Rotation={}}, cframeMt) end }
UDim = {new=function(s,o) return {Scale=s,Offset=o} end}
UDim2 = {new=function(xs,xo,ys,yo) return {X=UDim.new(xs,xo),Y=UDim.new(ys,yo)} end}
UDim2.fromOffset = function(x,y) return UDim2.new(0,x,0,y) end
Color3 = {new=function(...) return {...} end,fromRGB=function(...) return {...} end}
Enum = setmetatable({}, {__index=function(self,k)
    local group = setmetatable({}, {__index=function(_,value) return k..'.'..value end})
    rawset(self,k,group); return group
end})
math.clamp = function(x,lo,hi) return math.max(lo,math.min(hi,x)) end
table.clear = function(t) for k in pairs(t) do t[k]=nil end end
warn = function(err) failures[#failures+1]=err end
local clock = 0
os.clock = function() return clock end
local all = {}
local methods = {}
local function new(class)
    local obj = {_class=class,_props={Name=class,Position=v(0,0,0),Size=v(1,1,1),
        AssemblyLinearVelocity=v(0,0,0),AssemblyAngularVelocity=v(0,0,0),
        CFrame=CFrame.new(v(0,0,0)),AbsoluteSize=v(800,600,0),AbsolutePosition=v(0,0,0)},_signals={}}
    for _,name in ipairs({'AncestryChanged','ChildAdded','ChildRemoved','Destroying','Touched',
        'InputBegan','InputEnded','InputChanged','Activated','Event','DescendantAdded',
        'Heartbeat','CharacterRemoving','TouchTap'}) do obj._signals[name]=signal() end
    setmetatable(obj,{
        __index=function(t,k) if k=="ClassName" then return t._class end; return methods[k] or t._signals[k] or t._props[k] end,
        __newindex=function(t,k,value)
            t._props[k]=value
            if k=='CFrame' then t._props.Position=value.Position end
        end,
    })
    all[#all+1]=obj
    return obj
end
function methods:IsA(class) return self._class==class or class=='BasePart' and (self._class=='Part' or self._class=='MeshPart') end
function methods:GetChildren()
    local out={}
    for _,obj in ipairs(all) do if obj.Parent==self then out[#out+1]=obj end end
    return out
end
function methods:FindFirstChild(name)
    for _,child in ipairs(self:GetChildren()) do if child.Name==name then return child end end
end
function methods:WaitForChild(name) return assert(self:FindFirstChild(name),name) end
function methods:FindFirstChildOfClass(class)
    for _,child in ipairs(self:GetChildren()) do if child:IsA(class) then return child end end
end
function methods:IsDescendantOf(parent)
    local node=self.Parent
    while node do if node==parent then return true end; node=node.Parent end
    return false
end
function methods:GetFullName() return (self.Parent and self.Parent:GetFullName()..'.' or '')..self.Name end
function methods:GetPropertyChangedSignal(name)
    self._signals['property:'..name]=self._signals['property:'..name] or signal()
    return self._signals['property:'..name]
end
function methods:CaptureFocus() end
function methods:Fire(...) self.Event:Fire(...) end
function methods:Destroy()
    if self._destroyed then return end
    self._destroyed=true
    self.Destroying:Fire()
    for _,child in ipairs(self:GetChildren()) do child:Destroy() end
    self.Parent=nil
end
Instance={new=function(class,parent) local obj=new(class); obj.Parent=parent; return obj end}
local function child(parent,name,class)
    local obj=Instance.new(class or 'Folder',parent); obj.Name=name; return obj
end
local services={Workspace=new('Workspace'),Players=new('Players'),RunService=new('RunService'),
    UserInputService=new('UserInputService'),HttpService=new('HttpService'),GuiService=new('GuiService')}
function services.GuiService:GetGuiInset() return Vector2.new(0,58), Vector2.new(0,0) end
local lastReport
function services.HttpService:JSONEncode(data)
    local function serializable(value)
        local kind = type(value)
        assert(kind ~= 'function' and kind ~= 'userdata', 'non-JSON value in result')
        if kind == 'table' then
            assert(not value._class, 'Instance in result')
            for _, entry in pairs(value) do serializable(entry) end
        end
    end
    serializable(data)
    lastReport = data
    return '{"mockJSON":true}'
end
-- Roblox does not promise the ordering our original mock assumed.
-- Reverse Heartbeat listeners to reproduce the real same-frame return bug.
services.RunService._signals.Heartbeat=signal(TEST_HEARTBEAT_REVERSE ~= false)
local player=child(services.Players,'Tester','Player')
services.Players.LocalPlayer=player
local playerGui=child(player,'PlayerGui','PlayerGui')
function playerGui:GetGuiObjectsAtPosition() return {} end
local character=child(services.Workspace,'Tester','Model'); player.Character=character
local root=child(character,'HumanoidRootPart','Part')
local humanoid=child(character,'Humanoid','Humanoid'); humanoid.Health=100; humanoid.Sit=false
local animator=child(humanoid,'Animator','Animator')
local playingAnimations={{Name='Idle',Animation={AnimationId='rbxassetid://idle'},Priority='Idle',IsPlaying=true}}
function animator:GetPlayingAnimationTracks() return playingAnimations end
local miniGames=child(services.Workspace,'MiniGames')
local session=child(miniGames,'test-session')
local replicated=child(session,'Replicated')
local hitboxes=child(replicated,'Hitboxes')
local owner=child(hitboxes,player.Name)
local catchbox=child(owner,'CatchBox','Part')
catchbox.Position=v(0,-0.2,0); catchbox.Size=v(5.2,6.3,2.31)
local field=services.Workspace
for _,name in ipairs({'ParkMatchMap','Replicated','Fields','MatchField','Replicated'}) do field=child(field,name) end
local ball=child(field,'Football','MeshPart')
ball.Anchored=false; ball.Position=v(100,0,0); ball.AssemblyLinearVelocity=v(-90,0,0)
game={GetService=function(_,name) return assert(services[name],name) end}
local function step()
    clock=clock+0.04
    services.RunService.Heartbeat:Fire()
    assert(#failures==0,table.concat(failures,'\n'))
end
local function findButton(gui,text)
    for _,obj in ipairs(all) do if not obj._destroyed and (obj.Text==text or text=='Copy Result' and obj.Name=='CopyResult') and obj:IsA('TextButton') and obj:IsDescendantOf(gui) then return obj end end
    error('button missing: '..text)
end
local path=assert(TEST_SCRIPT_PATH,'TEST_SCRIPT_PATH missing')
dofile(path)
local gui=assert(playerGui:FindFirstChild('UFTracker'),'UI missing')
local panel=gui:FindFirstChild('Frame')
local slider=assert(panel:FindFirstChild('RadiusSlider'))
slider.AbsoluteSize=v(186,28,0); slider.AbsolutePosition=v(12,60,0)
local orb=assert(gui:FindFirstChild('UFDetectionOrb'))
local touch={UserInputType=Enum.UserInputType.Touch,Position=v(198,70,0)}
slider.InputBegan:Fire(touch)
assert(orb.Radius==100,'slider maximum failed')
touch.Position=v(12,70,0); services.UserInputService.InputChanged:Fire(touch)
assert(orb.Radius==5,'slider minimum failed')
touch.Position=v(12+186*15/95,70,0); services.UserInputService.InputChanged:Fire(touch)
assert(orb.Radius==20,'slider intermediate value failed')
services.UserInputService.InputEnded:Fire(touch)
touch.Position=v(198,70,0); services.UserInputService.InputChanged:Fire(touch)
assert(orb.Radius==20,'released slider still dragging')
step()
assert(root.Position.X==0,'outside ball must not move player')
local copy = findButton(gui,'Copy Result')
local copied
setclipboard = function(text) copied=text end
copy.Activated:Fire()
assert(copy.Text=='Copied! Send result' and copied:find('UF COPY RESULT v11',1,true), 'clipboard success failed')
assert(lastReport.schema==11 and lastReport.attempts==0 and lastReport.fieldPath[5].found, 'report metadata missing')
assert(lastReport.activeBalls[1].lastGate=='outside_orb' and lastReport.character.rootFound, 'live blocker missing')
assert(lastReport.fieldChildren[1].class=='MeshPart', 'targeted discovery context missing')
setclipboard = nil
copy.Activated:Fire()
local textBox = assert(panel:FindFirstChild('ResultText'))
assert(textBox.Visible and textBox.SelectionStart==1, 'missing-clipboard selectable fallback failed')
setclipboard = function() error('clipboard blocked') end
copy.Activated:Fire()
assert(textBox.Visible and textBox.Text:find('clipboard blocked',1,true), 'clipboard-error fallback failed')
toclipboard = function(text) copied=text end
copy.Activated:Fire()
assert(not textBox.Visible and copy.Text=='Copied! Send result', 'alternate clipboard fallback failed')
setclipboard, toclipboard = nil, nil
-- Fresh eligible ball discovered inside the orb: reproduces the reported no-trigger case.
ball:Destroy()
ball=child(field,'Football','MeshPart')
ball.Anchored=false; ball.Position=v(10,0,0); ball.AssemblyLinearVelocity=v(-90,0,0)
services.Workspace.DescendantAdded:Fire(ball)
step()
assert(root.Position.X==0,'attempt should begin without snapping immediately')
copy.Activated:Fire()
assert(lastReport.attempts==1 and lastReport.pendingMove~='none', 'attempt diagnostic missing')
step()
assert(root.Position.X>3.9 and root.Position.X<4.1,'slower approach intermediate position wrong')
step()
assert(root.Position.X>7.9 and root.Position.X<8.1,'approach should continue')
local tapCount, tapDownCount=0,0
local activeTouch
local injectedPoints={}
services.VirtualInputManager=new('VirtualInputManager')
function services.VirtualInputManager:SendTouchEvent(id,state,x,y)
    assert(state==0 or state==2,'invalid touch state')
    if state==0 then
        tapDownCount=tapDownCount+1
        activeTouch={id=id,at=clock}
        playingAnimations={{Name='TestCatch',Animation={AnimationId='rbxassetid://test-catch'},Priority='Action',IsPlaying=true}}
        services.UserInputService.InputBegan:Fire({UserInputType=Enum.UserInputType.Touch,UserInputState='Begin'},false)
    end
    if state==2 then
        assert(activeTouch and activeTouch.id==id,'unpaired touch release')
        activeTouch=nil
        services.UserInputService.InputEnded:Fire({UserInputType=Enum.UserInputType.Touch,UserInputState='End'},false)
        tapCount=tapCount+1
        injectedPoints[#injectedPoints+1]={x=x,y=y}
        services.UserInputService.TouchTap:Fire({Vector2.new(x,y-58)},false)
    end
end
-- A firesignal function must never short-circuit engine input in v8.
firesignal=function() error('obsolete firesignal must not be called') end
ball.Touched:Fire(catchbox)
assert(tapDownCount==1 and tapCount==0,'contact must press without same-callback release')
step()
assert(root.Position.X==10,'approach did not arrive at ball')
assert(tapDownCount==1 and tapCount==0,'arrival duplicated tap or released too early')
assert(math.abs(root.Position.Y-0.2)<1e-8,'CatchBox offset alignment failed')
step()
assert(tapCount==1,'held touch did not release on later heartbeat')
ball.Position=v(12,0,0)
step()
assert(root.Position.X==12,'hold should follow current ball position')
step(); step(); step(); step()
assert(root.Position.X==0,'hold timeout failed to restore')
for i=1,5 do
    findButton(gui,'Tap').Activated:Fire()
    local count=tapDownCount
    findButton(gui,'Tap').Activated:Fire()
    assert(tapDownCount==count,'overlapping manual input was not suppressed')
    step(); step()
end
for _,point in ipairs(injectedPoints) do
    assert(point.y==injectedPoints[1].y and point.y>58,'injected tap feedback drifted toward top bar')
end
copy.Activated:Fire()
assert(lastReport.input.realTapsObserved==0 and lastReport.input.ignoredSyntheticTaps>=6,
    'synthetic events misclassified as real taps')
local inputEvent, released, beganObserved, endedObserved
for _,event in ipairs(lastReport.events) do
    if event.kind=='catch_input' then inputEvent=event.data end
    if event.kind=='catch_input_release' then released=event.data end
    if event.kind=='engine_input_observed' and event.data.event=='InputBegan' then beganObserved=true end
    if event.kind=='engine_input_observed' and event.data.event=='InputEnded' then endedObserved=true end
end
assert(inputEvent.screenPoint.y==inputEvent.point.y+58 and inputEvent.guiInset.y==58,'inset not converted once')
assert(released and released.heldSeconds>=0.059 and released.released,'release hold duration not reported')
assert(beganObserved and endedObserved,'engine input observations missing')
local animationProbe
for _,event in ipairs(lastReport.events) do
    if event.kind=='input_animation_probe' and event.data.source=='local_catchbox_contact' then animationProbe=event.data end
end
assert(animationProbe and animationProbe.before.tracks[1].name=='Idle'
    and animationProbe.after.tracks[1].name=='TestCatch','before/after animation probe missing')
findButton(gui,'Tap').Activated:Fire()
assert(activeTouch,'manual test should have a pending press')
findButton(gui,'ON').Activated:Fire()
assert(not activeTouch,'OFF must release pending input immediately')
findButton(gui,'OFF').Activated:Fire()
firesignal=nil
services.VirtualInputManager=nil
copy.Activated:Fire()
local returned, arrived
for _,event in ipairs(lastReport.events) do
    if event.kind=='catch_attempt_return' then returned=event.data end
    if event.kind=='catch_arrived' then arrived=event.data end
end
assert(arrived and returned and returned.heartbeatDelta>=8 and returned.heldSeconds>=0.30,
    'approach and hold must span configured duration')
step()
assert(root.Position.X==0,'same instance triggered twice')
-- OFF suppresses new balls, ON re-evaluates overlap.
findButton(gui,'ON').Activated:Fire()
ball:Destroy()
ball=child(field,'Football','MeshPart')
ball.Anchored=false; ball.Position=v(15,0,0); ball.AssemblyLinearVelocity=v(-90,0,0)
services.Workspace.DescendantAdded:Fire(ball)
step(); assert(root.Position.X==0,'OFF still moved player')
findButton(gui,'OFF').Activated:Fire()
step(); step(); assert(root.Position.X>5 and root.Position.X<7,'ON did not begin slow approach')
findButton(gui,'ON').Activated:Fire()
assert(root.Position.X==0,'OFF did not immediately restore')
-- Close removes UI and listeners; rerun boots cleanly.
findButton(gui,'×').Activated:Fire()
assert(not playerGui:FindFirstChild('UFTracker'),'close did not remove UI')
step()
dofile(path)
assert(playerGui:FindFirstChild('UFTracker'),'rerun failed')
step(); step(); assert(root.Position.X>5 and root.Position.X<7,'rerun did not begin slow approach')
local replacement=playerGui:FindFirstChild('UFTracker')
dofile(path)
assert(replacement._destroyed and root.Position.X==0,'duplicate execution did not restore/clean prior copy')
step(); step()
assert(root.Position.X>0,'new attempt should advance before ball destruction')
ball:Destroy()
step()
assert(root.Position.X==0,'ball destruction during approach did not restore')
-- Without executor input APIs, arrival should log unsupported input without crashing.
local currentInputGui=playerGui:FindFirstChild('UFTracker')
ball=child(field,'Football','MeshPart')
ball.Anchored=false; ball.Position=v(10,0,0); ball.AssemblyLinearVelocity=v(-90,0,0)
services.Workspace.DescendantAdded:Fire(ball)
step(); step(); step(); step()
findButton(currentInputGui,'Copy Result').Activated:Fire()
assert(lastReport.input.lastResult=='unsupported_or_blocked','blocked input not reported')
ball:Destroy(); step()
assert(root.Position.X==0,'unsupported-input attempt did not restore')
local mouseEvents={}
services.VirtualInputManager=new('VirtualInputManager')
function services.VirtualInputManager:SendMouseButtonEvent(x,y,button,down)
    assert(button==0 and x>=0 and y>=0,'invalid mouse event')
    mouseEvents[#mouseEvents+1]=down
end
ball=child(field,'Football','MeshPart')
ball.Anchored=false; ball.Position=v(10,0,0); ball.AssemblyLinearVelocity=v(-90,0,0)
services.Workspace.DescendantAdded:Fire(ball)
step(); step(); step(); step(); step(); step()
assert(#mouseEvents==2 and mouseEvents[1]==true and mouseEvents[2]==false,'mouse fallback did not release')
findButton(currentInputGui,'Copy Result').Activated:Fire()
assert(lastReport.input.lastResult=='dispatched_VirtualInputManager_mouse','mouse fallback not reported')
ball:Destroy(); step()
services.VirtualInputManager=nil
-- Local association ends movement without snapping back, including subsequent OFF.
local currentGui=playerGui:FindFirstChild('UFTracker')
ball=child(field,'Football','MeshPart')
ball.Anchored=false; ball.Position=v(10,0,0); ball.AssemblyLinearVelocity=v(-90,0,0)
services.Workspace.DescendantAdded:Fire(ball)
step(); step()
local beforeAssociation=root.Position.X
assert(beforeAssociation>0,'local-association setup did not move')
ball.Parent=character; ball.AncestryChanged:Fire()
step()
assert(root.Position.X==beforeAssociation,'local association incorrectly snapped back')
findButton(currentGui,'Copy Result').Activated:Fire()
local kept
for _,event in ipairs(lastReport.events) do
    if event.kind=='catch_attempt_finished' then kept=event.data end
end
assert(kept and kept.positionKept and not kept.restored and kept.associatedPlayer==player.Name,
    'local association report missing')
findButton(currentGui,'ON').Activated:Fire()
assert(root.Position.X==beforeAssociation,'OFF undid completed local association')
-- Another player association still ends the attempt and returns the local player.
ball:Destroy(); root.CFrame=CFrame.new(v(0,0,0))
findButton(currentGui,'OFF').Activated:Fire()
ball=child(field,'Football','MeshPart')
ball.Anchored=false; ball.Position=v(10,0,0); ball.AssemblyLinearVelocity=v(-90,0,0)
services.Workspace.DescendantAdded:Fire(ball)
step(); step()
child(services.Players,'Other','Player')
local other=child(services.Workspace,'Other','Model')
ball.Parent=other; ball.AncestryChanged:Fire()
step()
assert(root.Position.X==0,'other-player association failed to return')
ball:Destroy()
ball=child(field,'Football','MeshPart')
ball.Anchored=false; ball.Position=v(10,0,0); ball.AssemblyLinearVelocity=v(-90,0,0)
services.Workspace.DescendantAdded:Fire(ball)
step(); step()
local beforeDisable=root.Position.X
ball.Parent=character -- Deliberately disable before the ancestry callback is delivered.
findButton(currentGui,'ON').Activated:Fire()
assert(root.Position.X==beforeDisable,'OFF snapped back before local ancestry delivery')

-- A processed UI target is skipped, and recorded top-screen taps are never replayed.
local blocker=child(playerGui,'BlockingControl','TextButton'); blocker.Visible=true; blocker.Active=true
function playerGui:GetGuiObjectsAtPosition(x,y)
    return x==400 and {blocker} or {}
end
local targetEvents={}
services.VirtualInputManager=new('VirtualInputManager')
function services.VirtualInputManager:SendTouchEvent(id,state,x,y)
    targetEvents[#targetEvents+1]={state=state,x=x,y=y}
end
for i=1,10 do step() end
services.UserInputService.TouchTap:Fire({Vector2.new(568.5,47)},false)
findButton(currentGui,'Tap').Activated:Fire()
assert(#targetEvents==1 and targetEvents[1].x==480 and targetEvents[1].y>200,
    'active UI not avoided or stale top-screen point reused')
step(); step()
findButton(currentGui,'Copy Result').Activated:Fire()
local checkedInput
for _,event in ipairs(lastReport.events) do if event.kind=='catch_input' then checkedInput=event.data end end
assert(#checkedInput.targetChecks==2 and #checkedInput.targetChecks[1].blockers==1,
    'hit-test evidence missing')
function playerGui:GetGuiObjectsAtPosition() return {blocker} end
local oldCount=#targetEvents
findButton(currentGui,'Tap').Activated:Fire()
assert(#targetEvents==oldCount,'blocked overlay should prevent input dispatch')
findButton(currentGui,'Copy Result').Activated:Fire()
assert(lastReport.input.lastResult=='unsupported_or_blocked','all-blocked input not reported')
assert(#failures==0,table.concat(failures,'\n'))
print('PASS: full-script mock boot, slider, clipboard success/failure/fallback, reports, slow approach, following hold, return, local/other association, held engine input/observations/manual test/dedup/coordinate feedback/UI targets/unsupported input, toggle and cleanup')

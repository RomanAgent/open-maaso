using System.Collections.Generic;
using System;
using System.Linq.Expressions;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;
using Object = UnityEngine.Object;

public sealed class LoginDoorwayTransitionTests
{
    private GameObject cameraObject, avatar, doorway;
    private Camera camera;
    private Behaviour framing;
    private Component rig;
    private ControllerProxy controller;
    private readonly List<LoginDoorwayResult> receipts = new();
    private int sequence;

    private static Type TypeOf(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    private void SetRig(string field, object value) => rig.GetType().GetField(field).SetValue(rig, value);
    private string FramingMode => (string)framing.GetType().GetProperty("FramingMode").GetValue(framing);
    [Serializable]
    public sealed class LoginDoorwayCommand
    {
        public string requestId, transitionId, phase;
        public int durationMs;
        public long sequence, expiresAtMs;
    }
    [Serializable]
    public sealed class LoginDoorwayResult
    {
        public string requestId, transitionId, phase, code;
        public bool ok;
    }
    private sealed class ControllerProxy
    {
        private readonly object target;
        public object Target => target;
        public ControllerProxy(List<LoginDoorwayResult> results)
        {
            Action<object> receive = value => results.Add(JsonUtility.FromJson<LoginDoorwayResult>(JsonUtility.ToJson(value)));
            Type resultType = TypeOf("LoginDoorwayResult");
            var parameter = Expression.Parameter(resultType);
            Delegate callback = Expression.Lambda(typeof(Action<>).MakeGenericType(resultType),
                Expression.Invoke(Expression.Constant(receive), Expression.Convert(parameter, typeof(object))), parameter).Compile();
            target = Activator.CreateInstance(TypeOf("LoginDoorwayTransitionController"), callback);
        }
        private object Call(string name, params object[] args) => target.GetType().GetMethod(name).Invoke(target, args);
        public bool OwnsCamera => (bool)target.GetType().GetProperty("OwnsCamera").GetValue(target);
        public void Advance(float now, long utc) => Call("Advance", now, utc);
        public void CancelForReset(string reason) => Call("CancelForReset", reason);
        public void Execute(LoginDoorwayCommand command, Behaviour framing, Component rig, bool allowed, float now, long utc) =>
            Call("Execute", JsonUtility.FromJson(JsonUtility.ToJson(command), TypeOf("LoginDoorwayCommand")), framing, rig, allowed, now, utc);
    }

    [SetUp]
    public void SetUp()
    {
        cameraObject = new GameObject("DoorwayTestCamera");
        camera = cameraObject.AddComponent<Camera>(); camera.aspect = .5f;
        framing = (Behaviour)cameraObject.AddComponent(TypeOf("FrontFullBodyCamera"));
        avatar = GameObject.CreatePrimitive(PrimitiveType.Cube);
        avatar.name = "ExistingAvatar"; avatar.transform.position = new Vector3(0, 1, 0);
        avatar.transform.localScale = new Vector3(.5f, 2, .3f);
        framing.GetType().GetProperty("TargetRoot").SetValue(framing, avatar.transform);
        framing.GetType().GetMethod("FrameNow").Invoke(framing, null);
        doorway = new GameObject("Doorway"); rig = doorway.AddComponent(TypeOf("LoginDoorwayRig"));
        SetRig("DoorHinge", Anchor("hinge", new Vector3(3, 0, 4)));
        SetRig("ExteriorCamera", Anchor("outside", new Vector3(2.5f, 1.3f, 5.15f)));
        SetRig("ThresholdCamera", Anchor("threshold", new Vector3(2.5f, 1.35f, 3.85f)));
        SetRig("InteriorCamera", Anchor("inside", new Vector3(1.45f, 1.35f, 2.5f)));
        SetRig("DoorLookTarget", Anchor("look", new Vector3(2.5f, .82f, 4.03f)));
        receipts.Clear(); sequence = 0;
        controller = new ControllerProxy(receipts);
    }

    [TearDown]
    public void TearDown()
    {
        controller.CancelForReset("test_end");
        Object.DestroyImmediate(doorway); Object.DestroyImmediate(avatar); Object.DestroyImmediate(cameraObject);
    }

    private Transform Anchor(string name, Vector3 position)
    { var item = new GameObject(name); item.transform.SetParent(doorway.transform); item.transform.position = position; return item.transform; }
    private LoginDoorwayCommand Command(string phase, int duration = 0, string transition = "doorway-test") => new()
    { requestId = "request-" + (++sequence), transitionId = transition, phase = phase, durationMs = duration, sequence = sequence, expiresAtMs = 10000 };
    private void Execute(LoginDoorwayCommand command, float now = 0, bool allowed = true) =>
        controller.Execute(command, framing, rig, allowed, now, 1000);

    private object SharedBinding()
    {
        object binding=Activator.CreateInstance(TypeOf("LoginDoorwaySceneBinding"));
        void Field(string name,object value)=>binding.GetType().GetField(name).SetValue(binding,value);
        Field("SceneRoot",doorway.transform);Field("SceneRevision","coastal-fixture");
        Field("ProtectedRoomBounds",new Bounds(new Vector3(2.2f,1.6f,-2.15f),new Vector3(3.6f,3.2f,3.7f)));
        var hinge=(Transform)rig.GetType().GetField("DoorHinge").GetValue(rig);
        var leaf=GameObject.CreatePrimitive(PrimitiveType.Cube);leaf.name="ExistingFormalEntryLeaf";
        leaf.transform.SetParent(hinge,false);leaf.transform.localPosition=new Vector3(-.485f,1.175f,0);leaf.transform.localScale=new Vector3(.97f,2.35f,.06f);
        Field("DoorHinge",hinge);Field("DoorLeaf",leaf.transform);Field("FrameRoot",Anchor("ExistingEntryFrame",new Vector3(2.5f,1.19f,4)));
        foreach(string name in new[]{"ExteriorCamera","ThresholdCamera","InteriorCamera","DoorLookTarget"}) Field(name,rig.GetType().GetField(name).GetValue(rig));
        Field("LobbyCamera",Anchor("LobbyCamera",new Vector3(0,1.35f,1.6f)));
        Field("LobbyLookTarget",Anchor("LobbyLook",new Vector3(0,1,0)));
        return binding;
    }
    private bool Bind(object binding)=>(bool)rig.GetType().GetMethod("BindSceneEntry").Invoke(rig,new[]{binding});
    private object RigCall(string method,params object[] args)=>rig.GetType().GetMethod(method).Invoke(rig,args);

    private (Component navigation,Component door) AddWestBedroomCameraRoute()
    {
        object binding=SharedBinding();binding.GetType().GetField("ProtectedRoomBounds").SetValue(binding,new Bounds(new Vector3(6,1.6f,2.2f),new Vector3(3.6f,3.2f,3.6f)));
        Assert.That(Bind(binding),Is.True);
        var nav=doorway.AddComponent(TypeOf("PersonalSpaceNavigation"));
        void Field(string name,object value)=>nav.GetType().GetField(name).SetValue(nav,value);
        Field("Revision","coastal-fixture");Field("WalkableRegions",new[]{new Bounds(new Vector3(0,.05f,0),new Vector3(8,.1f,8)),new Bounds(new Vector3(6,.05f,2.2f),new Vector3(3.6f,.1f,3.6f)),new Bounds(new Vector3(4.1f,.05f,2.1f),new Vector3(.2f,.1f,1))});
        Field("BedroomPortal",new Bounds(new Vector3(4.1f,1.15f,2.1f),new Vector3(.2f,2.3f,1)));
        Field("Obstacles",new[]{new Bounds(new Vector3(6.55f,.575f,2.1f),new Vector3(2.2f,1.15f,1.7f))});
        Field("RouteNodes",new[]{Anchor("BedroomApproach",new Vector3(3.25f,0,2.1f)),Anchor("BedroomInside",new Vector3(4.75f,0,2.1f)),Anchor("BedFoot",new Vector3(5.1f,0,2.1f)),Anchor("BedSouthCorner",new Vector3(5.1f,0,3.28f))});
        var pocket=doorway.AddComponent(TypeOf("PersonalSpacePocketDoor"));
        void DoorField(string name,object value)=>pocket.GetType().GetField(name).SetValue(pocket,value);
        DoorField("SlidingRoot",Anchor("BedroomSlide",new Vector3(4.12f,0,2.1f)));DoorField("ClosedLocalPosition",new Vector3(4.12f,0,2.1f));DoorField("OpenLocalPosition",new Vector3(4.12f,0,1.06f));Field("BedroomDoor",pocket);
        return(nav,pocket);
    }

    [TestCase(false)]
    [TestCase(true)]
    public void SafeBedroomCameraRouteWaitsForDoorAndReachesTheExistingSeatedOrLyingActor(bool lying)
    {
        var fixture=AddWestBedroomCameraRoute();
        avatar.transform.position=lying?new Vector3(6.5f,.75f,2.1f):new Vector3(6.3f,1,3.28f);
        avatar.transform.rotation=lying?Quaternion.Euler(-90,0,0):Quaternion.identity;
        Vector3 actorPosition=avatar.transform.position;Quaternion actorRotation=avatar.transform.rotation;
        Execute(Command("prepare"));Assert.That(receipts[^1].ok,Is.True,receipts[^1].code);
        Execute(Command("open"));Execute(Command("enter"));Vector3 lobby=camera.transform.position;
        Execute(Command("frame",300));controller.Advance(.2f,1000);
        Assert.That(camera.transform.position,Is.EqualTo(lobby),"Camera waits for actual sliding-door readiness.");
        controller.Advance(.35f,1000);
        var entryHinge=(Transform)rig.GetType().GetField("DoorHinge").GetValue(rig);
        Assert.That(Quaternion.Angle(entryHinge.localRotation,Quaternion.identity),Is.LessThan(.01f),
            "The entry closes behind the camera even while it waits for the bedroom door.");
        fixture.door.GetType().GetMethod("Advance").Invoke(fixture.door,new object[]{.5f});
        for(int frame=22;frame<900&&controller.OwnsCamera;frame++)
        {
            controller.Advance(frame/60f,1000);
            Assert.That(fixture.navigation.GetType().GetMethod("ContainsCamera").Invoke(fixture.navigation,new object[]{camera.transform.position,.08f}),Is.True);
            if(camera.transform.position.x>=4.2f&&camera.transform.position.x<=4.6f)
                Assert.That(Vector3.Dot(camera.transform.forward,(actorPosition-camera.transform.position).normalized),Is.GreaterThan(.65f),"Portal photography must look toward the current actor rather than the ceiling.");
        }
        Assert.That(receipts[^1].ok,Is.True,receipts[^1].code);Assert.That(controller.OwnsCamera,Is.False);
        Assert.That(camera.transform.position.x,Is.GreaterThan(4.2f));
        Assert.That(FramingMode,Is.EqualTo(lying?"sleeping_top":"hero_full_body"));
        framing.GetType().GetMethod("FrameNow").Invoke(framing,null);
        Assert.That(camera.transform.position.x,Is.GreaterThan(4.2f),"The scoped handoff must not snap back to the lobby.");
        Assert.That(avatar.transform.position,Is.EqualTo(actorPosition));Assert.That(avatar.transform.rotation,Is.EqualTo(actorRotation));
    }

    [Test] public void BedroomCameraDoorTimeoutIsTerminalAndLeavesTheActorUntouched()
    {
        AddWestBedroomCameraRoute();avatar.transform.position=new Vector3(6.3f,1,3.28f);Vector3 original=avatar.transform.position;
        Execute(Command("prepare"));Execute(Command("open"));Execute(Command("enter"));Execute(Command("frame",300));controller.Advance(2.1f,1000);
        Assert.That(receipts[^1].ok,Is.False);Assert.That(receipts[^1].code,Is.EqualTo("bedroom_door_timeout"));Assert.That(controller.OwnsCamera,Is.False);Assert.That(avatar.transform.position,Is.EqualTo(original));
    }

    [Test]
    public void SharedBindingReusesTheExistingLeafAndDoesNotHideLegacyGeometry()
    {
        object binding=SharedBinding(); Assert.That(Bind(binding),Is.True);
        int children=doorway.GetComponentsInChildren<Transform>(true).Length;
        var legacy=GameObject.CreatePrimitive(PrimitiveType.Cube);legacy.name="V2_Entrance_Baked";legacy.transform.SetParent(doorway.transform);
        var renderer=legacy.GetComponent<Renderer>();
        object selected=TypeOf("LoginDoorwayRig").GetMethod("BindSceneEntryInEnvironment").Invoke(null,new object[]{doorway.transform});
        Assert.That(selected,Is.SameAs(rig));Assert.That(renderer.enabled,Is.True,"Binding must never apply a name-based hide.");
        Assert.That(doorway.GetComponentsInChildren<Transform>(true).Length,Is.EqualTo(children+1));
        Assert.That(RigCall("ValidateEntryRoute"),Is.True);
    }
    [Test]
    public void OrdinaryRoomKeepsTheSharedEntryClosedUntilARealLoginLeaseOpensIt()
    {
        object binding=SharedBinding();Assert.That(Bind(binding),Is.True);
        Transform hinge=(Transform)rig.GetType().GetField("DoorHinge").GetValue(rig);
        Quaternion closed=hinge.localRotation;
        Assert.That(RigCall("TrySetSceneDoorOpen",1f),Is.True);
        rig.GetType().GetMethod("Start",BindingFlags.Instance|BindingFlags.NonPublic).Invoke(rig,null);
        Assert.That(Quaternion.Angle(closed,hinge.localRotation),Is.LessThan(.01f));
        object[] acquired={0L};Assert.That(rig.GetType().GetMethod("TryAcquire").Invoke(rig,acquired),Is.True);
        long lease=(long)acquired[0];
        Assert.That(RigCall("SetOpen",lease,1f),Is.True);
        rig.GetType().GetMethod("Start",BindingFlags.Instance|BindingFlags.NonPublic).Invoke(rig,null);
        Assert.That(Quaternion.Angle(closed,hinge.localRotation),Is.GreaterThan(80f));
        RigCall("Release",lease,true);
        Assert.That(Quaternion.Angle(closed,hinge.localRotation),Is.LessThan(.01f));
    }

    [Test]
    public void LoginClosesTheEntryOnlyAfterTheCameraHasEntered()
    {
        Assert.That(Bind(SharedBinding()),Is.True);
        var hinge=(Transform)rig.GetType().GetField("DoorHinge").GetValue(rig);
        Quaternion closed=hinge.localRotation;
        Execute(Command("prepare"));Execute(Command("open"));
        Assert.That(Quaternion.Angle(closed,hinge.localRotation),Is.GreaterThan(80f));
        Execute(Command("enter",1200));controller.Advance(.6f,1000);
        Assert.That(Quaternion.Angle(closed,hinge.localRotation),Is.GreaterThan(80f),
            "The door must remain open while the lens crosses the threshold.");
        controller.Advance(1.2f,1000);Execute(Command("frame",300),1.2f);
        controller.Advance(1.35f,1000);
        Assert.That(Quaternion.Angle(closed,hinge.localRotation),Is.InRange(20f,80f));
        controller.Advance(1.5f,1000);
        Assert.That(controller.OwnsCamera,Is.False);
        Assert.That(Quaternion.Angle(closed,hinge.localRotation),Is.LessThan(.01f));
        Assert.That(receipts[^1].ok,Is.True,receipts[^1].code);
    }

    [TestCase("prepare")]
    [TestCase("open")]
    [TestCase("enter")]
    [TestCase("frame")]
    public void SkipClosesTheEntryFromEveryLoginPhase(string phase)
    {
        Assert.That(Bind(SharedBinding()),Is.True);
        var hinge=(Transform)rig.GetType().GetField("DoorHinge").GetValue(rig);
        Quaternion closed=hinge.localRotation;
        Execute(Command("prepare"));
        if(phase!="prepare")Execute(Command("open"));
        if(phase is "enter" or "frame")Execute(Command("enter"));
        if(phase=="frame")Execute(Command("frame",300));
        Execute(Command("skip"),.1f);
        Assert.That(receipts[^1].ok,Is.True,receipts[^1].code);
        Assert.That(controller.OwnsCamera,Is.False);
        Assert.That(Quaternion.Angle(closed,hinge.localRotation),Is.LessThan(.01f));
    }

    [TestCase(false)]
    [TestCase(true)]
    public void CancelAndRendererResetRestoreTheClosedEntry(bool reset)
    {
        Assert.That(Bind(SharedBinding()),Is.True);
        var hinge=(Transform)rig.GetType().GetField("DoorHinge").GetValue(rig);
        Quaternion closed=hinge.localRotation;
        Execute(Command("prepare"));Execute(Command("open",650));controller.Advance(.3f,1000);
        Assert.That(Quaternion.Angle(closed,hinge.localRotation),Is.GreaterThan(20f));
        if(reset)controller.CancelForReset("renderer_disabled");
        else Execute(Command("cancel"),.3f);
        Assert.That(controller.OwnsCamera,Is.False);
        Assert.That(Quaternion.Angle(closed,hinge.localRotation),Is.LessThan(.01f));
    }

    [Test]
    public void CancellationPreservesAnExplicitRoomDoorPoseFromBeforeLogin()
    {
        Assert.That(Bind(SharedBinding()),Is.True);
        Assert.That(RigCall("TrySetSceneDoorOpen",.4f),Is.True);
        var hinge=(Transform)rig.GetType().GetField("DoorHinge").GetValue(rig);
        Quaternion roomPose=hinge.localRotation;
        Execute(Command("prepare"));Execute(Command("open"));Execute(Command("cancel"));
        Assert.That(controller.OwnsCamera,Is.False);
        Assert.That(Quaternion.Angle(roomPose,hinge.localRotation),Is.LessThan(.01f));
    }
    [Test]
    public void AmbiguousSharedEntryBindingsAreRejectedRatherThanPickingTheFirst()
    {
        object binding=SharedBinding();Assert.That(Bind(binding),Is.True);
        var duplicate=doorway.AddComponent(TypeOf("LoginDoorwayRig"));
        Assert.That(duplicate.GetType().GetMethod("BindSceneEntry").Invoke(duplicate,new[]{binding}),Is.EqualTo(true));
        Assert.That(TypeOf("LoginDoorwayRig").GetMethod("BindSceneEntryInEnvironment").Invoke(null,new object[]{doorway.transform}),Is.Null);
    }

    [Test]
    public void BedroomProtectionIsExplicitAndSupportsWestExtensionWithoutBlockingLivingRoom()
    {
        object binding=SharedBinding();
        binding.GetType().GetField("ProtectedRoomBounds").SetValue(binding,default(Bounds));
        Assert.That(Bind(binding),Is.False,"An omitted protected volume must not silently inherit an old quadrant.");
        // Blender X[-7.8,-4],Y[-4,-.4] -> Unity X[4,7.8],Z[.4,4].
        binding.GetType().GetField("ProtectedRoomBounds").SetValue(binding,
            new Bounds(new Vector3(5.9f,1.6f,2.2f),new Vector3(3.8f,3.2f,3.6f)));
        Assert.That(Bind(binding),Is.True);
        avatar.transform.position=new Vector3(2,1,-2);
        Assert.That(RigCall("MustHoldInLobby",avatar.transform,new Vector3(0,1.35f,1.6f)),Is.False);
        avatar.transform.position=new Vector3(6,1,2);
        Assert.That(RigCall("MustHoldInLobby",avatar.transform,new Vector3(0,1.35f,1.6f)),Is.True);
    }

    [Test]
    public void LegacyRoomHasNoAnimatedDoorCapabilityAndIsLeftUntouched()
    {
        int count=doorway.GetComponentsInChildren<Transform>(true).Length;
        Assert.That(TypeOf("LoginDoorwayRig").GetMethod("BindSceneEntryInEnvironment").Invoke(null,new object[]{doorway.transform}),Is.Null);
        Assert.That(doorway.GetComponentsInChildren<Transform>(true).Length,Is.EqualTo(count));
    }
    [Test]
    public void InvalidPortalRouteAndForeignLeafAreRejected()
    {
        object binding=SharedBinding();
        var threshold=(Transform)binding.GetType().GetField("ThresholdCamera").GetValue(binding);
        threshold.position=new Vector3(-2,1.35f,3.85f);
        Assert.That(Bind(binding),Is.False,"The sampled curve must cross the declared aperture.");
        threshold.position=new Vector3(2.5f,1.35f,3.85f);
        binding.GetType().GetField("DoorLeaf").SetValue(binding,avatar.transform);
        Assert.That(Bind(binding),Is.False,"Another actor or room cannot become the entry leaf.");
    }
    [Test]
    public void CompletedHandoffCannotCloseOrMoveAnEntryOwnedByTheRoomLater()
    {
        Assert.That(Bind(SharedBinding()),Is.True);
        Execute(Command("prepare"));Execute(Command("open"));Execute(Command("enter"));Execute(Command("frame"));
        Assert.That(receipts[^1].ok,Is.True);Assert.That(controller.OwnsCamera,Is.False);
        Assert.That(RigCall("TrySetSceneDoorOpen",.4f),Is.True);
        var hinge=(Transform)rig.GetType().GetField("DoorHinge").GetValue(rig);
        Quaternion rotation=hinge.localRotation;Vector3 position=camera.transform.position;
        controller.CancelForReset("late_renderer_cleanup");
        Assert.That(hinge.localRotation,Is.EqualTo(rotation));Assert.That(camera.transform.position,Is.EqualTo(position));
    }
    [Test]
    public void BedroomAvatarStaysInPlaceAndCameraStopsInLobbyAfterSpeechFraming()
    {
        object binding=SharedBinding();Assert.That(Bind(binding),Is.True);
        avatar.transform.position=new Vector3(2,1,-2);
        Vector3 actorPosition=avatar.transform.position;
        framing.GetType().GetProperty("TargetRoot").SetValue(framing,avatar.transform);
        Execute(Command("prepare"));Execute(Command("open"));Execute(Command("enter"));Execute(Command("frame"));
        var lobby=(Transform)binding.GetType().GetField("LobbyCamera").GetValue(binding);
        Assert.That(Vector3.Distance(camera.transform.position,lobby.position),Is.LessThan(.001f));
        framing.GetType().GetMethod("SetFramingMode").Invoke(framing,new object[]{"upper_body"});
        framing.GetType().GetMethod("FrameNow").Invoke(framing,null);
        Assert.That(Vector3.Distance(camera.transform.position,lobby.position),Is.LessThan(.001f));
        Assert.That(avatar.transform.position,Is.EqualTo(actorPosition));
    }
    [Test]
    public void RebindingDuringOpenRetiresTheOldDoorLeaseWithoutChangingNewState()
    {
        object binding=SharedBinding();Assert.That(Bind(binding),Is.True);
        Execute(Command("prepare"));Execute(Command("open",650));controller.Advance(.2f,1000);
        binding.GetType().GetField("SceneRevision").SetValue(binding,"new-room-revision");
        Assert.That(Bind(binding),Is.True);Assert.That(RigCall("TrySetSceneDoorOpen",.25f),Is.True);
        var hinge=(Transform)rig.GetType().GetField("DoorHinge").GetValue(rig);Quaternion rotation=hinge.localRotation;
        controller.Advance(.65f,1000);
        Assert.That(receipts[^1].ok,Is.False);Assert.That(hinge.localRotation,Is.EqualTo(rotation));
    }

    [Test]
    public void CameraMovesContinuouslyWhileExistingAvatarPoseAndIdentityStayFixed()
    {
        Vector3 actorPosition = avatar.transform.position; Quaternion actorRotation = avatar.transform.rotation;
        Execute(Command("prepare"));
        Assert.That(receipts[^1].ok, Is.True);
        Assert.That(controller.OwnsCamera, Is.True); Assert.That(framing.enabled, Is.False);
        Assert.That(camera.rect.height, Is.EqualTo(.48f).Within(.001f));
        Vector3 outside = camera.transform.position;
        float horizontalTan = Mathf.Tan(camera.fieldOfView * Mathf.Deg2Rad * .5f) * camera.aspect;
        Execute(Command("open", 650)); controller.Advance(.325f, 1000);
        Assert.That(camera.rect.height, Is.InRange(.49f, .99f));
        Assert.That(camera.transform.position.z, Is.LessThan(outside.z - .05f),
            "The camera should start moving while the door opens.");
        Assert.That(Mathf.Tan(camera.fieldOfView * Mathf.Deg2Rad * .5f) * camera.aspect,
            Is.EqualTo(horizontalTan).Within(.0001f), "Viewport expansion must preserve the door's horizontal projection.");
        controller.Advance(.65f, 1000); Vector3 openingEnd=camera.transform.position;
        Execute(Command("enter", 1200), .65f);
        Assert.That(Vector3.Distance(camera.transform.position, openingEnd), Is.LessThan(.001f),
            "Entering should continue the same camera path without snapping back.");
        controller.Advance(1.25f, 1000);
        Assert.That(camera.transform.position.z, Is.LessThan(outside.z));
        controller.Advance(1.86f, 1000); Execute(Command("frame", 300), 1.86f); controller.Advance(2.17f, 1000);
        Assert.That(controller.OwnsCamera, Is.False); Assert.That(framing.enabled, Is.True);
        Assert.That(FramingMode, Is.EqualTo("hero_full_body"));
        Assert.That(framing.GetType().GetProperty("VisibleBodyRatio").GetValue(framing),Is.EqualTo(1f));
        Assert.That(avatar.transform.position, Is.EqualTo(actorPosition));
        Assert.That(avatar.transform.rotation, Is.EqualTo(actorRotation));
        Assert.That(receipts.ConvertAll(result => result.phase), Is.EqualTo(new[] { "prepare", "open", "enter", "frame" }));
    }

    [Test]
    public void CancelRestoresCameraAndRejectsLateCommandsFromRetiredTransition()
    {
        Vector3 position = camera.transform.position; Quaternion rotation = camera.transform.rotation;
        Execute(Command("prepare")); Execute(Command("open", 650)); controller.Advance(.2f, 1000);
        Execute(Command("cancel"), .2f);
        Assert.That(controller.OwnsCamera, Is.False); Assert.That(framing.enabled, Is.True);
        Assert.That(Vector3.Distance(camera.transform.position, position), Is.LessThan(.001f));
        Assert.That(Quaternion.Angle(camera.transform.rotation, rotation), Is.LessThan(.01f));
        Execute(Command("enter", 1200));
        Assert.That(receipts[^1].ok, Is.False); Assert.That(receipts[^1].code, Is.EqualTo("transition_retired"));
    }

    [Test]
    public void ExactTransitionAndSequenceFenceStaleOrForeignRequests()
    {
        var prepare = Command("prepare"); Execute(prepare);
        Vector3 before = camera.transform.position;
        Execute(Command("open", 650, "other-transition"));
        Assert.That(receipts[^1].ok, Is.False); Assert.That(camera.transform.position, Is.EqualTo(before));
        var old = Command("open", 650); old.sequence = 1; Execute(old);
        Assert.That(receipts[^1].code, Is.EqualTo("stale_request"));
        Execute(prepare); Assert.That(receipts[^1].ok, Is.True, "An exact replay returns its receipt without moving.");
    }

    [Test]
    public void SkipReachesFinalFramingAndRendererResetStopsPendingMotion()
    {
        Execute(Command("prepare")); Execute(Command("open", 650));
        Execute(Command("skip"), .2f);
        Assert.That(controller.OwnsCamera, Is.False); Assert.That(camera.rect, Is.EqualTo(new Rect(0, 0, 1, 1)));
        Assert.That(FramingMode, Is.EqualTo("hero_full_body"));
        Execute(Command("prepare", transition: "second-transition"));
        Execute(Command("open", 650, "second-transition"));
        controller.CancelForReset("renderer_disabled");
        Assert.That(controller.OwnsCamera, Is.False);
        Assert.That(receipts[^1].code, Is.EqualTo("renderer_disabled"));
    }

    [Test]
    public void AuthorizationAndExpiryFailBeforeAnyCameraMutation()
    {
        Vector3 before = camera.transform.position;
        Execute(Command("prepare"), allowed: false);
        Assert.That(receipts[^1].ok, Is.False); Assert.That(controller.OwnsCamera, Is.False);
        var expired = Command("prepare"); expired.expiresAtMs = 999; Execute(expired);
        Assert.That(receipts[^1].code, Is.EqualTo("invalid_or_expired_request"));
        Assert.That(camera.transform.position, Is.EqualTo(before));
    }

    [TestCase("prepare")]
    [TestCase("restore")]
    [TestCase("holdHidden")]
    public void StaleOpportunisticHomeCommandsCannotStealDoorwayCamera(string phase)
    {
        Execute(Command("prepare"));
        Vector3 before = camera.transform.position;
        Component receiver = Receiver();
        try
        {
            Presence(receiver, phase, true);
            Assert.That(controller.OwnsCamera, Is.True);
            Assert.That(camera.transform.position, Is.EqualTo(before));
        }
        finally { Object.DestroyImmediate(receiver.gameObject); }
    }

    [Test]
    public void FreshExplicitHandoffKeepsPriorityOverDoorwayChoreography()
    {
        Execute(Command("prepare"));
        Component receiver = Receiver();
        try
        {
            Presence(receiver, "prepare", false);
            Assert.That(controller.OwnsCamera, Is.False);
        }
        finally { Object.DestroyImmediate(receiver.gameObject); }
    }

    [TestCase("framing")]
    [TestCase("bodyGesture")]
    public void ProductionArbiterCannotBypassDoorwayOwnership(string channel)
    {
        Execute(Command("prepare"));
        Component receiver = Receiver();
        try
        {
            Vector3 before = camera.transform.position;
            Type receiverType = receiver.GetType();
            Type commandType = receiverType.GetNestedType("AvatarArbiterCommand", BindingFlags.NonPublic);
            Type payloadType = receiverType.GetNestedType("AvatarArbiterRendererPayload", BindingFlags.NonPublic);
            object payload = JsonUtility.FromJson("{\"mode\":\"hero_full_body\",\"gesture\":\"wave\"}", payloadType);
            foreach (bool clear in new[] { false, true })
            {
                object command = JsonUtility.FromJson("{\"channel\":\"" + channel + "\",\"clearsChannel\":" + (clear ? "true" : "false") + "}", commandType);
                bool result = (bool)receiverType.GetMethod("ApplyAvatarArbiterMutation", BindingFlags.Instance | BindingFlags.NonPublic)
                    .Invoke(receiver, new[] { command, payload });
                Assert.That(result, Is.EqualTo(clear));
                Assert.That(controller.OwnsCamera, Is.True);
                Assert.That(camera.transform.position, Is.EqualTo(before));
            }
        }
        finally { Object.DestroyImmediate(receiver.gameObject); }
    }

    [Test]
    public void AuthorityResetReleasesDoorwayBeforeResettingTheRenderer()
    {
        Execute(Command("prepare")); Component receiver = Receiver();
        try
        {
            receiver.GetType().GetMethod("ResetAvatarArbiterState", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(receiver, null);
            Assert.That(controller.OwnsCamera, Is.False);
        }
        finally { Object.DestroyImmediate(receiver.gameObject); }
    }

    private Component Receiver()
    {
        camera.tag = "MainCamera";
        Component receiver = new GameObject("DoorwayReceiverTest").AddComponent(TypeOf("UnityAvatarCommandReceiver"));
        void Set(string name, object value) => receiver.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic).SetValue(receiver, value);
        Set("avatarRoot", avatar.transform); Set("bundledAvatarRoot", avatar.transform);
        Set("doorwayTransition", controller.Target);
        return receiver;
    }

    private static void Presence(Component receiver, string phase, bool opportunistic)
    {
        string json = "{\"requestId\":\"presence-request\",\"transitionId\":\"presence-transition\",\"phase\":\"" + phase +
            "\",\"edge\":\"right\",\"durationMs\":300,\"sequence\":1,\"expiresAtMs\":" +
            (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 5000) + ",\"doNotInterrupt\":" + (opportunistic ? "true" : "false") + "}";
        object command = JsonUtility.FromJson(json, TypeOf("AvatarPresenceCommand"));
        receiver.GetType().GetMethod("TransitionPresence", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(receiver, new[] { command });
    }
}

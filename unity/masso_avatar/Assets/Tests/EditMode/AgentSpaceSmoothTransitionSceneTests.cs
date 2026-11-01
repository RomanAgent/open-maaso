using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Linq.Expressions;
using System.Reflection;
using System.Text.RegularExpressions;
using Newtonsoft.Json.Linq;
using NUnit.Framework;
using UniVRM10;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.TestTools;
using Object = UnityEngine.Object;

/// <summary>Real shipped actor, authored room and sampled camera/locomotion frames.
/// EditMode reference PNGs explicitly use CPU-baked sampled bones, not player GPU QA.</summary>
public sealed class AgentSpaceSmoothTransitionSceneTests
{
    [TestCase(false)]
    [TestCase(true)]
    public void PersonalRoomRouteKeepsANormalBriskGaitAcrossIntermediateWaypoints(bool ownerFirst)
    {
        using var f = new SceneFixture("waypoint-walking");
        f.Command("enterAgentSpace", "entry", true, 0, 0);
        f.Until(() => f.HasReceipt("entry"), "enter", 15f);
        f.AssertSuccessful("entry");
        float distance = f.InstallDenseBedroomRoute();
        int idleAtIntermediate = 0, travelledFrames = 0;
        float travellingSeconds = 0f, travelled = 0f;
        int cruisingFrames = 0; float cruisingDistance = 0f;
        for (int frame = 0; frame < 1200 && !f.WalkingRouteComplete; frame++)
        {
            bool doorWasOpen = f.DoorIsOpen;
            Vector3 before = f.WalkingPosition;
            f.WalkingStep(1f / 60f, ownerFirst);
            float moved = Vector3.Distance(before, f.WalkingPosition);
            if (moved > .00001f)
            {
                travelled += moved; travellingSeconds += 1f / 60f; travelledFrames++;
            }
            if (f.CruisedLastStep && doorWasOpen)
            {
                cruisingFrames++; cruisingDistance += moved;
                Assert.That(moved, Is.GreaterThan(1.75f / 60f), "Continuous same-speed route frames must spend their remaining distance across intermediate nodes.");
            }
            if (!f.WalkingRouteComplete && f.HasIntermediateWaypoint && doorWasOpen && !f.IsWalking)
                idleAtIntermediate++;
        }
        Assert.That(f.WalkingRouteComplete, Is.True, "The final destination must settle within the bounded route.");
        Assert.That(idleAtIntermediate, Is.Zero, "Intermediate path nodes must not send the actor through idle and restart a walk.");
        Assert.That(travelledFrames, Is.GreaterThan(30));
        Assert.That(travelled, Is.EqualTo(distance).Within(.1f));
        Assert.That(travelled / travellingSeconds, Is.GreaterThan(1.65f),
            "Small reviewed waypoints must not stretch each 20 cm into a whole slow-motion footfall.");
        Assert.That(cruisingFrames, Is.GreaterThan(30));
        Assert.That(cruisingDistance / (cruisingFrames / 60f), Is.EqualTo(1.84f).Within(.03f));
        TestContext.WriteLine($"personal walking model={"Joy"} ownerFirst={ownerFirst} " +
            $"routeDistance={distance:F4} overallMovingSpeed={travelled / travellingSeconds:F4} " +
            $"cruiseSpeed={cruisingDistance / (cruisingFrames / 60f):F4} cruiseFrames={cruisingFrames} intermediateIdleFrames={idleAtIntermediate}");
        f.Command("leaveAgentSpace", "exit", true, .12f, .2f);
        f.Until(() => f.HasReceipt("exit"), "exit", 30f);
        f.AssertSuccessful("exit");
        Assert.That(f.Root.parent, Is.SameAs(f.HomeParent));
    }
    [TestCase(false)]
    [TestCase(true)]
    public void SelectedActorHasContinuousPortraitEntryAndLegalReturn(bool bedroom)
    {
        using var f = new SceneFixture(bedroom ? "bedroom" : "home");
        var home = f.Projection;
        Assert.That(f.DepthOfFieldStrength, Is.EqualTo(1f).Within(.001f));
        Transform selected = f.Root;
        Vector3 firstRootPosition = selected.position;
        Quaternion firstRootRotation = selected.rotation;
        f.Command("enterAgentSpace", "entry", true, 0, 0);
        f.AssertSameProjection(home, "first entry frame");
        Assert.That(f.DepthOfFieldStrength, Is.EqualTo(1f).Within(.001f), "Entry must not toggle the background effect in its first visible frame.");
        Assert.That(Vector3.Distance(selected.position, firstRootPosition), Is.LessThan(.0001f));
        Assert.That(Quaternion.Angle(selected.rotation, firstRootRotation), Is.LessThan(.01f));
        Assert.That(f.HasReceipt("entry"), Is.False);
        f.Record("entry-first", true);
        f.Until(() => f.HasReceipt("entry"), "enter", 15f);
        f.AssertSuccessful("entry");
        Assert.That(f.CameraPhase, Is.EqualTo("Active"));
        Assert.That(f.DepthOfFieldStrength, Is.EqualTo(0f).Within(.001f));
        Assert.That(f.SelectedRoot, Is.SameAs(selected));
        f.Record("entry-complete", true);

        if (bedroom)
        {
            f.WalkToAuthoredBedroom();
            f.CloseAuthoredPocketDoor();
            Assert.That(f.DoorIsOpen, Is.False, "The return must open the existing closed door.");
            Assert.That(f.DirectHomeSegmentIsClear, Is.False,
                "This fixture must require the authored portal route, not a straight teleport through its wall.");
        }
        var beforeExit = f.Projection;
        f.Command("leaveAgentSpace", "exit", true, .12f, .2f);
        f.AssertSameProjection(beforeExit, "first exit frame");
        Assert.That(f.DepthOfFieldStrength, Is.EqualTo(0f).Within(.001f), "Exit must preserve the active room's first frame before fading back to Home.");
        Assert.That(f.HasReceipt("exit"), Is.False);
        Assert.That(f.SelectedRoot, Is.SameAs(selected));
        f.Record("exit-first", true);
        f.Until(() => f.HasReceipt("exit"), "exit", 30f);
        f.AssertSuccessful("exit");
        Assert.That(f.CameraPhase, Is.EqualTo("Home"));
        Assert.That(f.SelectedRoot, Is.SameAs(selected));
        Assert.That(selected.parent, Is.SameAs(f.HomeParent));
        Assert.That(Quaternion.Angle(selected.rotation, f.HomeRotation), Is.LessThan(.15f));
        Assert.That(f.Framing.enabled, Is.True);
        Assert.That(f.DepthOfFieldStrength, Is.EqualTo(1f).Within(.001f));
        Assert.That(f.VerifiedReturnedHandoff,Is.True,"The actual release callback must preserve the last rendered root, bones and Animator clocks.");
        f.Record("exit-complete", true);
        var returned = f.Projection;
        f.Step("home-resumed");
        f.AssertSameProjection(returned, "first ordinary Home frame");
        if (bedroom) Assert.That(f.SawPocketDoorOpening, Is.True);
        f.Record("home-resumed", true);
    }

    [Test]
    public void DefaultRoomCameraFollowsEverySafeMovingTargetWithoutWaitingAtOldGoals()
    {
        using var f = new SceneFixture("continuous-camera-follow");
        var home = f.Projection;
        f.Command("enterAgentSpace", "entry", true);
        f.Until(() => f.HasReceipt("entry"), "enter", 15f);
        f.AssertSuccessful("entry");
        f.AssertSameProjection(home, "stationary entry retains the exact Home image");
        f.InstallDenseBedroomRoute();
        int movingSafeFrames = 0, stalledSafeFrames = 0;
        for (int frame = 0; frame < 1200 && !f.WalkingRouteComplete; frame++)
        {
            Vector3 cameraBefore = f.Camera.transform.position;
            var goalBefore = f.LatestPrivateCameraGoal();
            f.WalkingStep(1f / 60f);
            var goal = f.LatestPrivateCameraGoal();
            if (!f.DoorIsOpen)
                Assert.That(Call(f.Navigation, "CrossesBedroomPortal", cameraBefore,
                    new[] { f.Camera.transform.position }), Is.EqualTo(false),
                    "The continuously following camera cannot cross a still-closed pocket door.");
            if (Vector3.Distance(goalBefore.position, goal.position) <= .001f ||
                !f.CanFollowCameraDirectly(cameraBefore, goal.position, goal.subject)) continue;
            movingSafeFrames++;
            if (Vector3.Distance(cameraBefore, f.Camera.transform.position) < .00001f)
                stalledSafeFrames++;
        }
        Assert.That(f.WalkingRouteComplete, Is.True);
        Assert.That(movingSafeFrames, Is.GreaterThan(30), "This scene must exercise continuous safe follow segments.");
        Assert.That(stalledSafeFrames, Is.Zero,
            "A moving reachable target must not wait for an 18 cm route threshold or stop at an old short goal.");
        f.Command("leaveAgentSpace", "exit", true, .12f, .2f);
        f.Until(() => f.HasReceipt("exit"), "exit", 30f);
        f.AssertSuccessful("exit");
        Assert.That(f.VerifiedReturnedHandoff, Is.True);
    }

    [TestCase("hero_full_body")]
    [TestCase("upper_body")]
    public void DefaultRoomEntryKeepsFullHomeScaleAndRestoresFullBodyAfterInputFocus(string homeMode)
    {
        using var f=new SceneFixture("home-scale-"+homeMode);
        f.SetHomeFraming(homeMode);
        var home=f.Projection;
        f.Command("enterAgentSpace","entry",true);
        f.AssertSameProjection(home,"even focused input keeps the source image on the first entry frame");
        f.Until(()=>f.HasReceipt("entry"),"enter",15f);
        f.AssertSuccessful("entry");
        if(homeMode=="hero_full_body")f.AssertSameProjection(home,"completed full-body entry retains actual Home lens and pose");
        for(int frame=0;frame<60;frame++)f.Step("active-home-scale");
        f.AssertSameProjection(f.DefaultRoomProjection,"room settles at Home's ordinary full-body composition");
        f.AssertRoomShowsFullBody();
        f.SetSpaceFraming("upper_body");
        for(int frame=0;frame<180;frame++)f.Step("explicit-space-framing");
        Assert.That(f.UsesExplicitSpaceFraming,Is.True,"An explicit camera action retains its separate framing contract.");
        f.SetSpaceFraming("hero_full_body");
        Assert.That(f.UsesExplicitSpaceFraming,Is.False,"Returning to the default hero view restores the captured Home scale.");
        for(int frame=0;frame<240;frame++)f.Step("restored-default-space-framing");
        Assert.That(Vector3.Distance(f.Camera.transform.position,f.DefaultRoomProjection.position),Is.LessThan(.001f));
        Assert.That(f.Camera.fieldOfView,Is.EqualTo(f.DefaultRoomProjection.fov).Within(.001f),"A repeated/default hero request must restore normal full-body Home rather than input focus or the older world zoom.");
        f.Command("leaveAgentSpace","exit",true,.12f,.2f);
        f.Until(()=>f.HasReceipt("exit"),"exit",30f);
        f.AssertSuccessful("exit");
        Assert.That(f.VerifiedReturnedHandoff,Is.True);
    }

    [Test]
    public void InputFocusReleaseStillInFlightCannotLatchAnUpperBodyRoomDefault()
    {
        using var f=new SceneFixture("focus-release-in-flight");
        f.SetHomeFraming("upper_body");
        var upper=f.Projection;
        f.BeginHomeFullBodyRecovery();
        Assert.That(f.HomeIsRecoveringFullBody,Is.True);
        f.AssertSameProjection(upper,"logical neutral framing starts before its visible upper-body shot has moved");
        f.Command("enterAgentSpace","entry",true);
        f.AssertSameProjection(upper,"entry does not jump when the route cleared the logical focus override");
        f.Until(()=>f.HasReceipt("entry"),"enter",15f);f.AssertSuccessful("entry");
        for(int frame=0;frame<60;frame++)f.Step("active-restored-full-body");
        f.AssertSameProjection(f.DefaultRoomProjection,"an in-flight hero request resolves to ordinary Home full-body");
        f.AssertRoomShowsFullBody();
        f.Command("leaveAgentSpace","exit",true,.12f,.2f);
        f.Until(()=>f.HasReceipt("exit"),"exit",30f);f.AssertSuccessful("exit");
        Assert.That(f.VerifiedReturnedHandoff,Is.True);
    }

    [Test]
    public void ImmediateCleanupRetiresARealActorsPendingJourneyExactlyOnce()
    {
        using var f = new SceneFixture("cancel");
        f.Command("enterAgentSpace", "entry", true, 0, 0);
        f.Step("partial-entry");
        Assert.That(f.HasReceipt("entry"), Is.False);
        f.Command("leaveAgentSpace", "forced", false);
        Assert.That((string)f.Receipt("entry")["code"], Is.EqualTo("space_transition_cancelled"));
        f.AssertSuccessful("forced");
        Assert.That(f.Root.parent, Is.SameAs(f.HomeParent));
        for (int frame = 0; frame < 10; frame++) f.Step("after-cleanup");
        Assert.That(f.Receipts.Count(value => (string)value["requestId"] == "entry"), Is.EqualTo(1));
        Assert.That(f.Receipts.Any(value => (string)value["requestId"] == "entry" && (bool)value["ok"]), Is.False);
        f.Record("forced-complete", true);
    }

    [Test]
    public void ImmediateCloseFromTheBedroomReturnsHomeWithoutOpeningTheDoorOrWalkingBack()
    {
        using var f = new SceneFixture("immediate-bedroom-close");
        Transform selected = f.Root;
        f.Command("enterAgentSpace", "entry", true);
        f.Until(() => f.HasReceipt("entry"), "enter", 15f);
        f.AssertSuccessful("entry");
        Assert.That(f.CameraPhase, Is.EqualTo("Active"));
        f.WalkToAuthoredBedroom();
        f.CloseAuthoredPocketDoor();
        Assert.That(f.DoorIsOpen, Is.False);
        Assert.That(f.DirectHomeSegmentIsClear, Is.False,
            "The actor starts behind the real closed bedroom portal.");

        // Direct UI close must finish in this command, without stepping the
        // actor, door or camera through their normal return journey.
        f.Command("leaveAgentSpace", "exit", false);
        Assert.That(f.HasReceipt("exit"), Is.True);
        f.AssertSuccessful("exit");
        Assert.That(f.Root.parent, Is.SameAs(f.HomeParent));
        Assert.That(f.CameraPhase, Is.EqualTo("Home"));
        Assert.That(f.Framing.enabled, Is.True);
        Assert.That(f.SelectedRoot, Is.SameAs(selected));
        Assert.That(f.DoorIsOpen, Is.False);
        Assert.That(f.DoorHasPendingOpenRequest, Is.False);
        Assert.That(f.SawPocketDoorOpening, Is.False);
        f.Record("forced-complete");
    }

    private static Type A(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    private static Type W(string name) => Type.GetType("Maaso.World." + name + ", Assembly-CSharp", true);
    private static object Call(object value, string method, params object[] arguments)
    {
        MethodInfo found = value.GetType().GetMethods(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
            .Single(candidate => candidate.Name == method && candidate.GetParameters().Length == arguments.Length);
        try { return found.Invoke(value, arguments); }
        catch (TargetInvocationException error) { throw error.InnerException ?? error; }
    }
    private static T Field<T>(object value, string name) => (T)value.GetType()
        .GetField(name, BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public).GetValue(value);
    private static void Set(object value, string name, object data) => value.GetType()
        .GetField(name, BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public).SetValue(value, data);
    private static T Property<T>(object value, string name) => (T)value.GetType().GetProperty(name).GetValue(value);

    private sealed class SceneFixture : IDisposable
    {
        private const float Delta = 1f / 30f;
        public readonly Component Receiver, Controller, Map, Navigation, Portrait;
        public readonly Transform Root, HomeParent;
        public readonly Quaternion HomeRotation;
        public readonly Animator Animator;
        public readonly Camera Camera;
        public readonly Behaviour Framing;
        public readonly List<JObject> Receipts = new();
        private readonly GameObject room;
        private readonly Vrm10Instance vrm;
        private readonly string evidenceName;
        private readonly JArray frames = new();
        private float elapsed, entryCameraElapsed, exitCameraElapsed, exitJourneyElapsed;
        private Vector3 previousCamera, previousFoot;
        private Quaternion previousCameraRotation;
        private float previousFov, previousDepthOfField;
        private Component Director => Camera.GetComponent(W("WorldCameraDirector"));
        private Component Owner => Root.parent != null ? Root.parent.GetComponent(W("WorldOwnerAvatarLease")) : null;
        private Component Door => Field<Component>(Navigation, "BedroomDoor");
        public bool SawPocketDoorOpening;
        public bool VerifiedReturnedHandoff;
        private bool wrappedReturnHandoff,validateReleasedCamera;
        private (Vector3 position,Quaternion rotation,float fov,Rect rect,float aspect) releasedProjection;
        private (Vector3 position,Quaternion rotation,float fov,Rect rect,float aspect) initialHomeProjection;
        private Vector3 initialHomeAvatarPosition;
        private bool hasInitialHomeProjection;
        private bool hadExplicitSpaceFraming;
        private bool initialHomeWasFocused;
        public (Vector3 position,Quaternion rotation,float fov,Rect rect,float aspect) DefaultRoomProjection {get;private set;}
        public Transform SelectedRoot => Property<Transform>(Receiver, "ActiveAvatarRoot");
        public string CameraPhase => Director != null ? Field<object>(Director, "phase").ToString() : "Home";
        public float DepthOfFieldStrength => Property<float>(Portrait, "RenderStrength");
        public bool DoorIsOpen => Property<bool>(Door, "IsOpen");
        public bool DoorHasPendingOpenRequest => Field<bool>(Door, "requested");
        public Vector3 WalkingPosition => Owner.transform.position;
        public bool IsWalking => Property<bool>(Owner, "IsMoving");
        public bool HasIntermediateWaypoint => Field<int>(Controller, "waypoint") < Field<List<Vector3>>(Controller, "route").Count - 1;
        public bool WalkingRouteComplete => Field<int>(Controller, "waypoint") >= Field<List<Vector3>>(Controller, "route").Count && !IsWalking;
        public bool CruisedLastStep;
        public bool UsesExplicitSpaceFraming=>Field<bool>(Director,"privateCameraModeExplicit");
        public bool HomeIsRecoveringFullBody=>Property<bool>(Framing,"IsTransitioningToDefaultFullBody");
        public void BeginHomeFullBodyRecovery()=>Call(Framing,"SetFramingModeCore","hero_full_body",true);
        public (Vector3 position, Bounds subject) LatestPrivateCameraGoal()
        {
            object[] pose = { null, 0f, default(Bounds) };
            Assert.That(Call(Director, "TryGetPrivateDestination", pose), Is.EqualTo(true));
            return (Property<Vector3>(pose[0], "Position"), (Bounds)pose[2]);
        }
        public bool CanFollowCameraDirectly(Vector3 from, Vector3 to, Bounds subject) =>
            (bool)Call(Navigation, "CameraSegmentAvoidsSubject", from, to, subject) &&
            (!(bool)Call(Navigation, "CrossesBedroomPortal", from, new[] { to }) || DoorIsOpen);
        public void SetHomeFraming(string mode)
        {
            Call(Framing,"SetFramingMode",mode);Call(Framing,"FrameNow");
            // Establish the user-selected Home shot before this independent
            // entry scenario; no room transition has begun yet.
            previousCamera=Camera.transform.position;previousCameraRotation=Camera.transform.rotation;
            previousFov=Camera.fieldOfView;previousFoot=Root.position;
        }
        public void SetSpaceFraming(string mode)
        {hadExplicitSpaceFraming=true;Call(Controller,"SetFraming",mode);}
        public bool DirectHomeSegmentIsClear => (bool)Call(Navigation, "SegmentIsClear", Owner.transform.position,
            Property<Transform>(Map, "HomeAgentAnchor").position);
        public (Vector3 position, Quaternion rotation, float fov, Rect rect, float aspect) Projection =>
            (Camera.transform.position, Camera.transform.rotation, Camera.fieldOfView, Camera.rect, Camera.aspect);
        private static string Output => Environment.GetEnvironmentVariable("MAASO_AGENT_SPACE_EVIDENCE") ??
            Path.Combine(Path.GetTempPath(), "maaso-agent-space-smooth-scene");

        public SceneFixture(string scenario)
        {
            evidenceName = "joy" + "-" + scenario;
            EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
            Receiver = Object.FindAnyObjectByType(A("UnityAvatarCommandReceiver")) as Component;
            Vrm10Instance initialVrm = Object.FindAnyObjectByType<Vrm10Instance>();
            Assert.That(Receiver, Is.Not.Null); Assert.That(initialVrm, Is.Not.Null);
            int materialSlots = initialVrm.GetComponentsInChildren<Renderer>()
                .Where(item => item is SkinnedMeshRenderer || item is MeshRenderer)
                .Sum(item => item.sharedMaterials.Length);
            for (int index = 0; index < materialSlots; index++)
                LogAssert.Expect(LogType.Error, new Regex("Instantiating material due to calling renderer\\.material"));
            Call(Receiver, "Awake");

            Root = SelectedRoot;
            Assert.That(Root, Is.Not.Null);
            {
                var selectedVrm = Root.GetComponentInChildren<Vrm10Instance>(true);
                Assert.That(selectedVrm, Is.SameAs(initialVrm));
                Assert.That(AssetDatabase.GetAssetPath(PrefabUtility.GetCorrespondingObjectFromSource(selectedVrm.gameObject)),
                    Is.EqualTo("Assets/MaasoAvatar/Models/Default/Joy.vrm"));
            }
            Animator = Root.GetComponentInChildren<Animator>(true);
            Assert.That(Animator.isHuman && Animator.avatar.isValid, Is.True);
            Animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            Animator.Rebind();
            Call(Receiver, "TryStartDesignedIdle", Field<string>(Receiver, "designedIdleStateName"));
            Animator.Update(.25f);
            vrm = Root.GetComponentInChildren<Vrm10Instance>(true);
            vrm?.Runtime.Process();
            Send("setLocalAvatarVisible", new JObject { ["visible"] = true });
            room = Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));
            Map = room.GetComponent(W("PersistentWorldMapController"));
            W("PersistentWorldMapController").GetField("current", BindingFlags.NonPublic | BindingFlags.Static).SetValue(null, Map);
            Set(Map, "avatarReceiver", Receiver);
            Navigation = room.GetComponentInChildren(A("PersonalSpaceNavigation"));
            Assert.That(Navigation, Is.Not.Null);
            Assert.That(room.GetComponentsInChildren<Renderer>(true).Length, Is.GreaterThan(20), "Use the authored room, not replacement cubes.");
            Call(Map, "SetWorldActive", false);
            Assert.That(Call(Map, "AlignHomeAvatar", Root), Is.EqualTo(true));
            Camera = Camera.main;
            Assert.That(Camera, Is.Not.Null);
            Camera.aspect = 393f / 852f;
            Framing = Camera.GetComponent(A("FrontFullBodyCamera")) as Behaviour;
            Framing.GetType().GetProperty("TargetRoot").SetValue(Framing, Root);
            Call(Framing, "SetViewportSafeArea", .12f, .2f);
            Call(Framing, "FrameNow");
            // Player bootstraps this same effect after scene load; EditMode
            // explicitly attaches it so these sampled frames exercise the
            // real production eligibility and strength, not a fake counter.
            Portrait = Camera.GetComponent(A("PortraitDepthOfField")) ??
                Camera.gameObject.AddComponent(A("PortraitDepthOfField"));
            Call(Portrait, "OnEnable");
            Assert.That(Call(Portrait, "UpdateFocus"), Is.EqualTo(true));
            HomeParent = Root.parent; HomeRotation = Root.rotation;
            Controller = Receiver.GetComponent(A("AgentSpaceController")) ?? Receiver.gameObject.AddComponent(A("AgentSpaceController"));
            previousCamera = Camera.transform.position; previousCameraRotation = Camera.transform.rotation;
            previousFov = Camera.fieldOfView; previousFoot = Root.position;
            Record("home-initial");
        }

        private void Send(string method, JObject body) => Call(Receiver, "OnFlutterCommand",
            new JObject { ["method"] = method, ["json"] = body.ToString() }.ToString());
        public void Command(string method, string request, bool animated, float? top = null, float? bottom = null)
        {
            if(method=="enterAgentSpace")
            {
                initialHomeProjection=Projection;initialHomeAvatarPosition=Root.position;hasInitialHomeProjection=true;
                initialHomeWasFocused=Property<float>(Framing,"VisibleBodyRatio")<.999f || HomeIsRecoveringFullBody;
                DefaultRoomProjection=initialHomeProjection;
                if(initialHomeWasFocused)
                {
                    Component entry=(Component)A("LoginDoorwayRig").GetMethod("Ensure").Invoke(null,new object[]{Map});
                    var before=Projection;
                    string mode=Property<string>(Framing,"FramingMode");
                    object[] query={Root,entry,null,0f};
                    Assert.That(Call(Framing,"TryGetDefaultHomeFullBodyFramingPose",query),Is.EqualTo(true));
                    object pose=query[2];
                    DefaultRoomProjection=(Property<Vector3>(pose,"Position"),Property<Quaternion>(pose,"Rotation"),
                        (float)query[3],before.rect,before.aspect);
                    AssertSameProjection(before,"pure full-body query cannot move the input-focused camera");
                    Assert.That(Property<string>(Framing,"FramingMode"),Is.EqualTo(mode));
                }
                hadExplicitSpaceFraming=false;
            }
            if (method == "enterAgentSpace" && animated) entryCameraElapsed = 0;
            if (method == "leaveAgentSpace" && animated) { exitCameraElapsed = 0; exitJourneyElapsed = 0; }
            object command = Activator.CreateInstance(A("AgentSpaceCommand"));
            Set(command, "requestId", request); Set(command, "sessionId", "scene-" + evidenceName); Set(command, "animated", animated);
            if (top.HasValue) Set(command, "viewportTop", top.Value);
            if (bottom.HasValue) Set(command, "viewportBottom", bottom.Value);
            Type result = A("AgentSpaceResult");
            ParameterExpression parameter = Expression.Parameter(result);
            Action<object> receive = value => Receipts.Add(JObject.Parse(JsonUtility.ToJson(value)));
            Delegate callback = Expression.Lambda(typeof(Action<>).MakeGenericType(result),
                Expression.Invoke(Expression.Constant(receive), Expression.Convert(parameter, typeof(object))), parameter).Compile();
            Call(Controller, "ExecuteAsync", method, command, callback);
        }
        public bool HasReceipt(string request) => Receipts.Any(value => (string)value["requestId"] == request);
        public JObject Receipt(string request) => Receipts.Single(value => (string)value["requestId"] == request);
        public void AssertSuccessful(string request) => Assert.That((bool)Receipt(request)["ok"], Is.True, Receipt(request).ToString());
        public void AssertSameProjection((Vector3 position, Quaternion rotation, float fov, Rect rect, float aspect) expected, string label)
        {
            Assert.That(Vector3.Distance(Camera.transform.position, expected.position), Is.LessThan(.0001f), label);
            Assert.That(Quaternion.Angle(Camera.transform.rotation, expected.rotation), Is.LessThan(.01f), label);
            Assert.That(Camera.fieldOfView, Is.EqualTo(expected.fov).Within(.0001f), label);
            Assert.That(Camera.rect, Is.EqualTo(expected.rect), label);
            Assert.That(Camera.aspect, Is.EqualTo(expected.aspect), label);
        }
        public void Until(Func<bool> completed, string stage, float deadline)
        {
            for (int frame = 0; frame < Mathf.CeilToInt(deadline / Delta) && !completed(); frame++) Step(stage);
            Assert.That(completed(), Is.True, stage + " did not finish within the bounded native route.");
        }
        public void Step(string stage)
        {
            elapsed += Delta;
            if (Field<bool>(Controller, "leaving")) exitJourneyElapsed += Delta;
            Animator.Update(Delta);
            FreezeAutomaticCameraTick();
            Call(Controller, "LateUpdate");
            Component owner = Owner;
            if (owner != null) { Call(owner, "EnsureCurrentAvatarGrounded"); Call(owner, "AdvanceLocomotion", Delta); }
            vrm?.Runtime.Process();
            if (Door != null) Call(Door, "Advance", Delta);
            if (Director != null && CameraPhase != "Home")
            {
                float now = Time.realtimeSinceStartup;
                Set(Director, "privateCameraTick", now - Delta);
                if (CameraPhase == "Entering")
                { entryCameraElapsed += Delta; Set(Director, "transitionStartedAt", now - entryCameraElapsed); }
                if (CameraPhase == "Leaving")
                {
                    exitCameraElapsed += Delta; Set(Director, "transitionStartedAt", now - exitCameraElapsed);
                    WrapReturnedHandoff();
                }
                Call(Director, "UpdateTransition", now);
            }
            FreezeAutomaticCameraTick();
            Call(Controller, "LateUpdate");
            if (Framing.enabled) Call(Framing, "AdvanceFraming", Delta);
            if(validateReleasedCamera)
            {
                AssertSameProjection(releasedProjection,"same-frame Home camera ownership handoff");
                validateReleasedCamera=false;
            }
            if (Door != null && Field<float>(Door, "progress") > 0f && !DoorIsOpen)
                SawPocketDoorOpening = true;
            Record(stage);
        }

        private void WrapReturnedHandoff()
        {
            if(wrappedReturnHandoff)return;
            Action original=Field<Action>(Director,"transitionCompleted");
            if(original==null)return;
            wrappedReturnHandoff=true;
            Set(Director,"transitionCompleted",(Action)(()=>
            {
                Vector3 rootPosition=Root.position,rootScale=Root.lossyScale;
                Quaternion rootRotation=Root.rotation;
                var bones=Root.GetComponentsInChildren<Transform>(true)
                    .Select(bone=>(bone,position:bone.position,rotation:bone.rotation)).ToArray();
                var clocks=Enumerable.Range(0,Animator.layerCount)
                    .Select(layer=>Animator.GetCurrentAnimatorStateInfo(layer)).ToArray();
                List<Vector3> skin=RenderedSkinVertices();
                releasedProjection=Projection;
                original();
                Assert.That(Root.parent,Is.SameAs(HomeParent));
                Assert.That(Vector3.Distance(Root.position,rootPosition),Is.LessThan(.0001f),"Native release must not resample animated foot height at the last frame.");
                Assert.That(Quaternion.Angle(Root.rotation,rootRotation),Is.LessThan(.01f));
                Assert.That(Vector3.Distance(Root.lossyScale,rootScale),Is.LessThan(.0001f));
                foreach(var pose in bones)
                {
                    Assert.That(Vector3.Distance(pose.bone.position,pose.position),Is.LessThan(.0001f),"Handoff moved bone "+pose.bone.name);
                    Assert.That(Quaternion.Angle(pose.bone.rotation,pose.rotation),Is.LessThan(.01f),"Handoff rotated bone "+pose.bone.name);
                }
                for(int layer=0;layer<clocks.Length;layer++)
                {
                    AnimatorStateInfo current=Animator.GetCurrentAnimatorStateInfo(layer);
                    Assert.That(current.fullPathHash,Is.EqualTo(clocks[layer].fullPathHash));
                    Assert.That(current.normalizedTime,Is.EqualTo(clocks[layer].normalizedTime).Within(.0001f),"Native release reset the idle Animator clock.");
                }
                List<Vector3> restoredSkin=RenderedSkinVertices();
                Assert.That(restoredSkin.Count,Is.EqualTo(skin.Count));
                float maximum=0;
                for(int vertex=0;vertex<skin.Count;vertex++)maximum=Mathf.Max(maximum,Vector3.Distance(skin[vertex],restoredSkin[vertex]));
                Assert.That(maximum,Is.LessThan(.0002f),"The last rendered skin must not jump when Home regains ownership.");
                AssertSameProjection(releasedProjection,"native owner release camera");
                VerifiedReturnedHandoff=true;validateReleasedCamera=true;
                TestContext.WriteLine($"{evidenceName} handoff renderedSkinMaxDelta={maximum:R} vertices={skin.Count} rootDelta={Vector3.Distance(Root.position,rootPosition):R}");
            }));
        }

        private List<Vector3> RenderedSkinVertices()
        {
            var vertices=new List<Vector3>();
            foreach(var skin in Root.GetComponentsInChildren<SkinnedMeshRenderer>(true))
            {
                if(!skin.enabled||!skin.gameObject.activeInHierarchy||skin.sharedMesh==null)continue;
                var mesh=new Mesh();
                try {skin.BakeMesh(mesh);foreach(Vector3 vertex in mesh.vertices)vertices.Add(skin.transform.TransformPoint(vertex));}
                finally {Object.DestroyImmediate(mesh);}
            }
            Assert.That(vertices,Is.Not.Empty);
            return vertices;
        }
        private void FreezeAutomaticCameraTick()
        {
            if (Field<bool>(Controller, "leaving"))
                Set(Controller, "privateReturnStartedAt", Time.realtimeSinceStartup - exitJourneyElapsed);
            if (Director == null || CameraPhase == "Home") return;
            // Phase queries can advance the real clock. CPU BakeMesh sampling
            // is slower than a player frame, so only our explicit 30 Hz tick
            // may move the camera; a query must not add a second travel step.
            Set(Director, "privateCameraTick", float.PositiveInfinity);
            if (CameraPhase == "Entering")
                Set(Director, "transitionStartedAt", Time.realtimeSinceStartup - entryCameraElapsed);
            if (CameraPhase == "Leaving")
                Set(Director, "transitionStartedAt", Time.realtimeSinceStartup - exitCameraElapsed);
        }
        public void WalkToAuthoredBedroom()
        {
            Transform destination = room.GetComponentsInChildren<Transform>(true).Single(value => value.name == "V4_RuntimeBedFootSouth");
            object[] request = { Owner.transform.position, destination.position, Field<Transform[]>(Navigation, "RouteNodes"), null };
            Assert.That(Call(Navigation, "TryBuildRoute", request), Is.EqualTo(true));
            // Set up the same approved semantic route the native screen ray
            // would produce; do not teleport the actor into the remote room.
            Set(Controller, "route", (List<Vector3>)request[3]); Set(Controller, "waypoint", 0);
            Until(() => Vector3.Distance(Owner.transform.position, destination.position) < .015f &&
                !Property<bool>(Owner, "IsMoving"), "walk-bedroom", 20f);
            for (int frame = 0; frame < 120; frame++) Step("bedroom-camera-settle");
            Record("bedroom-settled", true);
        }
        public void CloseAuthoredPocketDoor()
        {
            Set(Door, "progress", 0f); Set(Door, "requested", false);
            Field<Transform>(Door, "SlidingRoot").localPosition = Field<Vector3>(Door, "ClosedLocalPosition");
            SawPocketDoorOpening = false;
        }
        public float InstallDenseBedroomRoute()
        {
            Component rig = room.GetComponentInChildren(A("AvatarFurnitureRig"));
            object bed = Call(rig, "Find", "bed");
            Transform destination = Field<Transform>(bed, "Approach");
            object[] planned = { Owner.transform.position, destination.position, Field<Transform[]>(Navigation, "RouteNodes"), null };
            Assert.That(Call(Navigation, "TryBuildRoute", planned), Is.EqualTo(true));
            var dense = new List<Vector3>();
            Vector3 previous = Owner.transform.position; float distance = 0f;
            foreach (Vector3 point in (List<Vector3>)planned[3])
            {
                float length = Vector3.Distance(previous, point); distance += length;
                int parts = Mathf.Max(1, Mathf.CeilToInt(length / .22f));
                for (int part = 1; part <= parts; part++) dense.Add(Vector3.Lerp(previous, point, (float)part / parts));
                previous = point;
            }
            Assert.That(dense.Count, Is.GreaterThan(8));
            Set(Controller, "route", dense); Set(Controller, "waypoint", 0);
            Call(Controller, "BindRouteContinuation");
            return distance;
        }
        public void WalkingStep(float delta, bool ownerFirst = false)
        {
            Animator.Update(delta);
            CruisedLastStep = !Field<bool>(Owner, "settleAtTarget") && IsWalking;
            Vector3 previous = Owner.transform.position;
            Vector3 previousDirection = Field<Vector3>(Owner, "targetPosition") - previous; previousDirection.y = 0f;
            if (!ownerFirst) Call(Controller, "AdvanceRoute");
            Call(Owner, "AdvanceLocomotion", delta);
            if (ownerFirst) Call(Controller, "AdvanceRoute");
            CruisedLastStep &= !Field<bool>(Owner, "settleAtTarget") && IsWalking;
            Vector3 nextDirection = Field<Vector3>(Owner, "targetPosition") - Owner.transform.position; nextDirection.y = 0f;
            CruisedLastStep &= previousDirection.sqrMagnitude > .000001f && nextDirection.sqrMagnitude > .000001f &&
                Vector3.Dot(previousDirection.normalized, nextDirection.normalized) > .999f;
            vrm?.Runtime.Process();
            if (Door != null) Call(Door, "Advance", delta);
            Assert.That(Call(Navigation, "ContainsFoot", Owner.transform.position), Is.EqualTo(true));
            Assert.That(Call(Navigation, "SegmentIsClear", previous, Owner.transform.position), Is.EqualTo(true));
            if (Director != null && CameraPhase != "Home")
            {
                Set(Director, "privateCameraTick", Time.realtimeSinceStartup - delta);
                Call(Director, "UpdateTransition", Time.realtimeSinceStartup);
            }
            FreezeAutomaticCameraTick();
            Record("walking-route");
        }
        public void Record(string stage, bool capture = false)
        {
            Assert.That(Call(Portrait, "UpdateFocus"), Is.EqualTo(true), stage + " lost the actual DOF focus.");
            float depthOfField = DepthOfFieldStrength;
            Assert.That(SelectedRoot, Is.SameAs(Root), "A route must not replace the selected character.");
            Renderer[] visible = Root.GetComponentsInChildren<Renderer>(true).Where(value => value.enabled && !value.forceRenderingOff &&
                (Camera.cullingMask & (1 << value.gameObject.layer)) != 0).ToArray();
            Assert.That(visible, Is.Not.Empty, stage + " has no visible actor mesh.");
            object[] query = { Root, new List<Renderer>(), null, false };
            Assert.That(A("AvatarVisualBounds").GetMethod("TryGetCurrent").Invoke(null, query), Is.EqualTo(true));
            Bounds body = (Bounds)query[2];
            Vector3 center = Camera.WorldToViewportPoint(body.center);
            Assert.That(center.z, Is.GreaterThan(Camera.nearClipPlane), stage);
            Rect projected = Project(body);
            if(hasInitialHomeProjection && Director!=null &&
                !Field<bool>(Controller,"leaving") &&
                (CameraPhase=="Entering" || CameraPhase=="Active") &&
                !hadExplicitSpaceFraming && !UsesExplicitSpaceFraming && Field<string>(Director,"privateFurniturePhase")=="standing" &&
                Vector3.Distance(Root.position,initialHomeAvatarPosition)<.002f)
            {
                var expected=initialHomeProjection;
                expected.position+=Root.position-initialHomeAvatarPosition;
                if(!initialHomeWasFocused)
                    AssertSameProjection(expected,stage+" ordinary full-body entry must keep the Home camera");
                // Compare the same live animated body in its original Home
                // optics, so natural idle bone motion cannot fake a zoom.
                Rect homeBody=ProjectFromPose(body,expected.position,expected.rotation,expected.fov,expected.aspect);
                if(initialHomeWasFocused)
                    Assert.That(projected.height,Is.LessThanOrEqualTo(homeBody.height+.0002f),stage+" input-focus recovery may pull back but cannot magnify the body");
                else
                {
                    Assert.That(projected.height,Is.EqualTo(homeBody.height).Within(.0002f),stage+" magnifies the current animated body");
                    Assert.That(projected.width,Is.EqualTo(homeBody.width).Within(.0002f));
                }
            }
            float visibleWidth = Mathf.Max(0, Mathf.Min(1, projected.xMax) - Mathf.Max(0, projected.xMin));
            float visibleHeight = Mathf.Max(0, Mathf.Min(1, projected.yMax) - Mathf.Max(0, projected.yMin));
            Assert.That(visibleWidth * visibleHeight, Is.GreaterThan(.001f), stage + " loses the actor from the image.");
            Assert.That(Call(Navigation, "ContainsCamera", Camera.transform.position, .08f), Is.EqualTo(true), stage + " leaves the authored indoor camera space.");
            Component owner = Owner;
            Vector3 foot = owner != null ? owner.transform.position : Root.position;
            Assert.That(Call(Navigation, "ContainsFoot", foot), Is.EqualTo(true), stage + " leaves the authored walkable floor.");
            if (frames.Count > 0 && stage != "forced-complete" && !stage.StartsWith("after-cleanup", StringComparison.Ordinal))
            {
                Assert.That(Vector3.Distance(Camera.transform.position, previousCamera), Is.LessThan(.16f), stage + " camera jumps between sampled frames.");
                Assert.That(Quaternion.Angle(Camera.transform.rotation, previousCameraRotation), Is.LessThan(15f), stage);
                Assert.That(Mathf.Abs(Camera.fieldOfView - previousFov), Is.LessThan(4f), stage);
                Assert.That(Mathf.Abs(depthOfField - previousDepthOfField), Is.LessThanOrEqualTo(.1f),
                    stage + " toggles the background blur between sampled frames.");
                if (stage.StartsWith("enter", StringComparison.Ordinal))
                    Assert.That(depthOfField, Is.LessThanOrEqualTo(previousDepthOfField + .0001f), stage + " reverses the entry fade.");
                if (stage.StartsWith("exit", StringComparison.Ordinal))
                    Assert.That(depthOfField, Is.GreaterThanOrEqualTo(previousDepthOfField - .0001f), stage + " reverses the Home fade.");
                Assert.That(Call(Navigation, "CameraSegmentIsClear", previousCamera, Camera.transform.position, .08f), Is.EqualTo(true), stage);
                Assert.That(Call(Navigation, "SegmentIsClear", previousFoot, foot), Is.EqualTo(true), stage + " crosses a wall or furniture.");
                if (!DoorIsOpen && Vector3.Distance(previousFoot, foot) > .0001f)
                    Assert.That(Call(Navigation, "CrossesBedroomPortal", previousFoot, new[] { foot }), Is.EqualTo(false),
                        stage + " crosses the closed pocket door before it opens.");
            }
            frames.Add(new JObject { ["stage"] = stage, ["elapsed"] = elapsed, ["actorId"] = Root.GetEntityId().ToString(),
                ["cameraPosition"] = V(Camera.transform.position), ["cameraRotation"] = Q(Camera.transform.rotation),
                ["fieldOfView"] = Camera.fieldOfView, ["cameraRect"] = R(Camera.rect), ["aspect"] = Camera.aspect,
                ["rootPosition"] = V(Root.position), ["footPosition"] = V(foot),
                ["projectedBounds"] = R(projected), ["cameraPhase"] = CameraPhase,
                ["depthOfFieldStrength"] = depthOfField, ["depthOfFieldEligible"] = Property<bool>(Portrait, "CanRender"),
                ["doorOpen"] = DoorIsOpen, ["walking"] = owner != null && Property<bool>(owner, "IsMoving") });
            previousCamera = Camera.transform.position; previousCameraRotation = Camera.transform.rotation;
            previousFov = Camera.fieldOfView; previousFoot = foot;
            previousDepthOfField = depthOfField;
            if (capture) CaptureCpuReference(stage, visible);
        }
        private static JArray V(Vector3 value) => new(value.x, value.y, value.z);
        private static JArray Q(Quaternion value) => new(value.x, value.y, value.z, value.w);
        private static JArray R(Rect value) => new(value.x, value.y, value.width, value.height);
        private Rect Project(Bounds bounds)
        {
            Vector2 min = new(float.PositiveInfinity, float.PositiveInfinity), max = new(float.NegativeInfinity, float.NegativeInfinity);
            for (int x = -1; x <= 1; x += 2) for (int y = -1; y <= 1; y += 2) for (int z = -1; z <= 1; z += 2)
            {
                Vector3 point = Camera.WorldToViewportPoint(bounds.center + Vector3.Scale(bounds.extents, new Vector3(x, y, z)));
                Assert.That(float.IsNaN(point.x) || float.IsInfinity(point.x) || float.IsNaN(point.y) || float.IsInfinity(point.y), Is.False);
                min = Vector2.Min(min, point); max = Vector2.Max(max, point);
            }
            return Rect.MinMaxRect(min.x, min.y, max.x, max.y);
        }

        public void AssertRoomShowsFullBody()
        {
            object[] query={Root,new List<Renderer>(),null,false};
            Assert.That(A("AvatarVisualBounds").GetMethod("TryGetCurrent").Invoke(null,query),Is.EqualTo(true));
            Rect body=Project((Bounds)query[2]);
            Assert.That(body.yMin,Is.GreaterThanOrEqualTo(.2f-.005f),"Full-body room entry keeps Home's lower margin and visible feet.");
            Assert.That(body.yMax,Is.LessThanOrEqualTo(.88f+.005f),"Full-body room entry keeps Home's top margin and visible head.");
        }

        private static Rect ProjectFromPose(Bounds bounds,Vector3 position,Quaternion rotation,float fov,float aspect)
        {
            Vector2 min=new(float.PositiveInfinity,float.PositiveInfinity),max=new(float.NegativeInfinity,float.NegativeInfinity);
            float tangent=Mathf.Tan(fov*Mathf.Deg2Rad*.5f);
            for(int x=-1;x<=1;x+=2)for(int y=-1;y<=1;y+=2)for(int z=-1;z<=1;z+=2)
            {
                Vector3 point=Quaternion.Inverse(rotation)*(bounds.center+Vector3.Scale(bounds.extents,new Vector3(x,y,z))-position);
                Vector2 viewport=new(.5f+point.x/(2*tangent*aspect*point.z),.5f+point.y/(2*tangent*point.z));
                min=Vector2.Min(min,viewport);max=Vector2.Max(max,viewport);
            }
            return Rect.MinMaxRect(min.x,min.y,max.x,max.y);
        }
        private void CaptureCpuReference(string stage, Renderer[] visible)
        {
            if (SystemInfo.graphicsDeviceType == UnityEngine.Rendering.GraphicsDeviceType.Null) return;
            var snapshots = new List<GameObject>(); var meshes = new List<Mesh>(); var hidden = new List<SkinnedMeshRenderer>();
            RenderTexture priorTarget = Camera.targetTexture, priorActive = RenderTexture.active;
            var target = new RenderTexture(393, 852, 24, RenderTextureFormat.ARGB32);
            var pixels = new Texture2D(393, 852, TextureFormat.RGBA32, false);
            try
            {
                foreach (SkinnedMeshRenderer skin in visible.OfType<SkinnedMeshRenderer>())
                {
                    var mesh = new Mesh(); skin.BakeMesh(mesh); meshes.Add(mesh);
                    var copy = new GameObject("Sampled CPU skin reference"); snapshots.Add(copy);
                    copy.layer = skin.gameObject.layer; copy.transform.SetParent(skin.transform, false);
                    copy.AddComponent<MeshFilter>().sharedMesh = mesh;
                    copy.AddComponent<MeshRenderer>().sharedMaterials = skin.sharedMaterials;
                    skin.enabled = false; hidden.Add(skin);
                }
                Camera.targetTexture = target; Camera.Render(); RenderTexture.active = target;
                pixels.ReadPixels(new Rect(0, 0, 393, 852), 0, 0); pixels.Apply();
                Directory.CreateDirectory(Output); File.WriteAllBytes(Path.Combine(Output, evidenceName + "-cpu-" + stage + ".png"), pixels.EncodeToPNG());
            }
            finally
            {
                Camera.targetTexture = priorTarget; RenderTexture.active = priorActive;
                foreach (SkinnedMeshRenderer skin in hidden) if (skin != null) skin.enabled = true;
                foreach (GameObject copy in snapshots) Object.DestroyImmediate(copy);
                foreach (Mesh mesh in meshes) Object.DestroyImmediate(mesh);
                Object.DestroyImmediate(pixels); target.Release(); Object.DestroyImmediate(target);
            }
        }
        public void Dispose()
        {
            Directory.CreateDirectory(Output);
            File.WriteAllText(Path.Combine(Output, evidenceName + "-frames.json"), new JObject {
                ["renderReference"] = "Synchronous EditMode sampled Animator/VRM CPU BakeMesh reference; not player GPU capture",
                ["frames"] = frames, ["receipts"] = JArray.FromObject(Receipts) }.ToString());
            if (Controller != null) Call(Controller, "CancelForReset");
            if (Receiver != null) Call(Receiver, "OnDisable");
            if (room != null) Object.DestroyImmediate(room);
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        }
    }
}

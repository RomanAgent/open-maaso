using System;
using System.IO;
using System.Reflection;
using System.Linq;
using System.Collections;
using System.Threading;
using System.Threading.Tasks;
using UniVRM10;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.TestTools;
using Object = UnityEngine.Object;

public sealed class DeskWorkHomeCameraTests
{
    private const string Session = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    private Vrm10Instance runtimeAvatar;
    private static Type AvatarType(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    private static object Call(object subject, string name, params object[] args) => subject.GetType()
        .GetMethods(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
        .Single(method => method.Name == name && method.GetParameters().Length == args.Length)
        .Invoke(subject, args);

    [Test]
    public void CameraLateUpdateRunsAfterTheReceiverContactPoseAndVrmProcess()
    {
        EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
        try
        {
            MonoBehaviour camera = (MonoBehaviour)Camera.main.GetComponent(AvatarType("FrontFullBodyCamera"));
            MonoBehaviour receiver = Object.FindObjectsByType<MonoBehaviour>(FindObjectsSortMode.None)
                .Single(value => value.GetType() == AvatarType("UnityAvatarCommandReceiver"));
            Vrm10Instance vrm = Object.FindAnyObjectByType<Vrm10Instance>();
            int Order(MonoBehaviour component)
            {
                int explicitlyConfigured = MonoImporter.GetExecutionOrder(MonoScript.FromMonoBehaviour(component));
                return explicitlyConfigured != 0 ? explicitlyConfigured
                    : component.GetType().GetCustomAttribute<DefaultExecutionOrder>()?.order ?? 0;
            }
            int cameraOrder = Order(camera), receiverOrder = Order(receiver), vrmOrder = Order(vrm);
            Assert.That(receiverOrder, Is.EqualTo(10000));
            Assert.That(vrmOrder, Is.EqualTo(11000));
            Assert.That(cameraOrder, Is.GreaterThan(receiverOrder), "The camera must sample the body after the receiver applies its final furniture pose.");
            Assert.That(cameraOrder, Is.GreaterThan(vrmOrder), "The camera must sample the same post-ControlRig pose that will be rendered.");
        }
        finally { EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single); }
    }

    [TestCase(0f, "upper_body", false, 0)]
    [TestCase(.000001f, "upper_body", false, 0)]
    [TestCase(0f, "head", false, 0)]
    [TestCase(.000001f, "head", false, 0)]
    [TestCase(0f, "hero_full_body", false, 0)]
    [TestCase(.000001f, "hero_full_body", false, 0)]
    [TestCase(0f, "upper_body", true, 0)]
    [TestCase(.033288f, "upper_body", false, 1)]
    [TestCase(.033288f, "upper_body", false, 2)]
    public void PublishedHomeDeskCameraEndsBehindAndAboveTheSeatedAvatarWithItsWorkspaceVisible(float engineDelta, string returnMode, bool rearm, int phoneStart)
    {
        if (runtimeAvatar == null) EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
        GameObject actor = runtimeAvatar != null ? runtimeAvatar.gameObject : Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm"));
        GameObject cameraObject = Camera.main.gameObject;
        GameObject room = Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));
        object controller = null;
        try
        {
            actor.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            Animator animator = actor.GetComponentInChildren<Animator>(true);
            if (phoneStart != 0) animator.runtimeAnimatorController = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>("Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller");
            animator.Rebind(); animator.Update(0f); animator.enabled = phoneStart != 0;
            Camera camera = cameraObject.GetComponent<Camera>();
            camera.tag = "MainCamera"; camera.aspect = 390f / 844f; camera.fieldOfView = 58f;
            Component framing = cameraObject.GetComponent(AvatarType("FrontFullBodyCamera"));
            Assert.That((framing as Behaviour).isActiveAndEnabled, Is.True);
            Assert.That(camera.isActiveAndEnabled, Is.True);
            Assert.That(Camera.main, Is.SameAs(camera));
            Type worldType = Type.GetType("Maaso.World.WorldCameraDirector, Assembly-CSharp", true);
            Component world = cameraObject.GetComponent(worldType) ?? cameraObject.AddComponent(worldType);
            Assert.That(worldType.GetProperty("OwnsCamera").GetValue(world), Is.EqualTo(false));
            framing.GetType().GetProperty("TargetRoot").SetValue(framing, actor.transform);
            Component map = room.GetComponent(Type.GetType("Maaso.World.PersistentWorldMapController, Assembly-CSharp", true));
            Call(map, "SetWorldActive", false);
            Assert.That(Call(map, "AlignHomeAvatar", actor.transform), Is.EqualTo(true));
            Vector3 initialRoot=actor.transform.position;
            Quaternion initialFacing=actor.transform.rotation;
            Call(framing, "SetViewportSafeArea", .16f, .133f);
            Component rig = room.GetComponentInChildren(AvatarType("AvatarFurnitureRig"));
            controller = Activator.CreateInstance(AvatarType("AvatarFurniturePoseController"));
            if (runtimeAvatar != null)
            {
                Type sampler = Type.GetType("Maaso.Avatar.AvatarVrmContactPoseSampler, Maaso.VrmBridge", true);
                object synchronize = sampler.GetMethod("Capture").Invoke(null, new object[] { runtimeAvatar.Runtime, actor.transform });
                controller.GetType().GetProperty("SynchronizeContactPose").SetValue(controller, synchronize);
            }
            object desk = Call(rig, "Find", "desk");
            Transform Point(string name) => (Transform)desk.GetType().GetField(name).GetValue(desk);
            Call(framing, "SetFramingMode", "upper_body");
            Assert.That(Call(controller, "BeginWorkSession", Session, actor.transform, animator, rig, 0f,
                (Action<string>)(phase => {
                    Call(framing, "SetFurniturePoseActive", phase != "standing");
                    object workAnchor = controller.GetType().GetProperty("WorkAnchor").GetValue(controller);
                    Call(framing, "SetDeskWorkAnchor", workAnchor);
                }), (Action<bool>)(_ => {})), Is.EqualTo(true));
            for (float now = 0f; now <= 15f; now += 1f / 60f)
            {
                if (phoneStart != 0) animator.Update(1f / 60f);
                Call(controller, "Advance", now, 1f / 60f);
                if (runtimeAvatar != null) runtimeAvatar.Runtime.Process();
                Call(framing, "AdvanceFraming", 1f / 60f);
            }
            Assert.That(controller.GetType().GetProperty("Phase").GetValue(controller), Is.EqualTo("working"));
            if (phoneStart != 0)
            {
                camera.transform.position = phoneStart != 2 ? new Vector3(-2.98f, 1.49f, 2.67f)
                    : animator.GetBoneTransform(HumanBodyBones.Head).position-Point("Seat").forward*.08f;
                camera.fieldOfView = 103.68f;
            }
            Vector3 requestStart = camera.transform.position;
            Component initialEntry = room.GetComponentInChildren(AvatarType("LoginDoorwayRig"));
            object initialNavigation = initialEntry.GetType().GetProperty("Navigation").GetValue(initialEntry);
            bool startInRoom = (bool)Call(initialNavigation, "ContainsCamera", requestStart, .08f);
            object[] initialSolverArgs = { actor.transform, "desk_over_shoulder", initialEntry, Vector3.forward, false,
                null, 0f, default(Bounds), false };
            Assert.That(Call(framing, "TryGetInteriorOwnedFramingPose", initialSolverArgs), Is.EqualTo(true));
            Bounds initialExclusion = (Bounds)initialSolverArgs[7]; initialExclusion.Expand(.16f);
            bool startInsideSubject = initialExclusion.Contains(requestStart);
            if (phoneStart == 2)
            {
                Assert.That(startInRoom, Is.True, "The escape regression must start inside the real room.");
                Assert.That(startInsideSubject, Is.True, "The escape regression must start inside the actual working body's bounds.");
            }
            if (phoneStart != 0) Call(framing, "SetFramingModeCore", "desk_over_shoulder", true);
            else Call(framing, "SetFramingMode", "desk_over_shoulder");
            if (phoneStart >= 2) Assert.That(Vector3.Distance(requestStart, camera.transform.position), Is.LessThan(.001f),
                "Starting inside the dynamic actor exclusion must begin a bounded route without an immediate jump.");
            float monotonicNow = Time.realtimeSinceStartup;
            for (int frame = 0; frame < 1200; frame++)
            {
                monotonicNow += 1f / 60f;
                if (phoneStart != 0)
                {
                    animator.Update(1f / 60f);
                    Call(controller, "Advance", 15f + frame / 60f, 1f / 60f);
                    if (runtimeAvatar != null) runtimeAvatar.Runtime.Process();
                }
                Vector3 previous = camera.transform.position;
                Call(framing, "AdvanceOwnedFramingFrame", engineDelta, monotonicNow);
                if (phoneStart != 0)
                {
                    bool previousInRoom = (bool)Call(initialNavigation, "ContainsCamera", previous, .08f);
                    if (previousInRoom) Assert.That(Vector3.Distance(previous, camera.transform.position), Is.LessThanOrEqualTo(1.4f * Mathf.Max(engineDelta, 1f / 60f) + .002f),
                        "The desk camera must move through its safe route, not teleport out of the actor.");
                }
            }
            Transform head = animator.GetBoneTransform(HumanBodyBones.Head);
            Transform seat = Point("Seat"), surface = Point("WorkSurface");
            Component entry = room.GetComponentInChildren(AvatarType("LoginDoorwayRig"));
            Assert.That(entry.GetType().GetProperty("IsSceneEntryBound").GetValue(entry), Is.EqualTo(true));
            object navigation = entry.GetType().GetProperty("Navigation").GetValue(entry);
            if (rearm)
            {
                framing.GetType().GetProperty("TargetRoot").SetValue(framing, actor.transform);
                Call(framing, "SetDeskWorkAnchor", controller.GetType().GetProperty("WorkAnchor").GetValue(controller));
                object lobby = entry.GetType().GetProperty("LobbyPose").GetValue(entry);
                camera.transform.SetPositionAndRotation((Vector3)lobby.GetType().GetProperty("Position").GetValue(lobby),
                    (Quaternion)lobby.GetType().GetProperty("Rotation").GetValue(lobby));
                Call(framing, "SetFramingMode", "desk_over_shoulder");
                Assert.That(framing.GetType().GetField("deskTravelActive", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(framing), Is.EqualTo(true));
                for (int frame = 0; frame < 1200; frame++)
                {
                    monotonicNow += 1f / 60f;
                    Call(framing, "AdvanceOwnedFramingFrame", engineDelta, monotonicNow);
                }
            }
            object[] desiredArgs = { default(Bounds), false, Matrix4x4.identity, 58f };
            object desired = Call(framing, "CalculateFramedPose", desiredArgs);
            Vector3 desiredPosition = (Vector3)desired.GetType().GetProperty("Position").GetValue(desired);
            Vector3 current = camera.transform.position;
            object[] solverArgs = { actor.transform, "desk_over_shoulder", entry, Vector3.forward, false,
                null, 0f, default(Bounds), false };
            bool solver = (bool)Call(framing, "TryGetInteriorOwnedFramingPose", solverArgs);
            Vector3 solved = solver ? (Vector3)solverArgs[5].GetType().GetProperty("Position").GetValue(solverArgs[5]) : Vector3.zero;
            object path = framing.GetType().GetField("homeInteriorPath", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(framing);
            int waypoint = (int)framing.GetType().GetField("homeInteriorWaypoint", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(framing);
            Vector3 goal = (Vector3)framing.GetType().GetField("homeInteriorGoal", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(framing);
            var facts = new Facts {
                model = "Joy", cameraPosition = current, cameraRotation = camera.transform.rotation,
                fieldOfView = camera.fieldOfView, desiredPosition = desiredPosition, seatPosition = seat.position,
                headPosition = head.position, deskPosition = surface.position, seatForward = seat.forward,
                cameraForward = camera.transform.forward,
                solverSucceeded = solver, solvedPosition = solved, goalPosition = goal,
                pathCount = path is System.Collections.ICollection route ? route.Count : -1, waypoint = waypoint,
                desiredInsideRoom = (bool)Call(navigation, "ContainsCamera", desiredPosition, .08f),
                actualInsideRoom = (bool)Call(navigation, "ContainsCamera", current, .08f),
                subjectCenter = ((Bounds)solverArgs[7]).center, subjectSize = ((Bounds)solverArgs[7]).size,
                phoneStart = phoneStart,
                startInRoom = startInRoom, startInsideSubject = startInsideSubject, startPosition = requestStart,
            };
            string output = Environment.GetEnvironmentVariable("MAASO_DESK_CAMERA_EVIDENCE") ?? Path.Combine(Path.GetTempPath(), "maaso-desk-home-camera");
            Directory.CreateDirectory(output);
            File.WriteAllText(Path.Combine(output, facts.model + (phoneStart != 0 ? "-phone-start-" + phoneStart : "") + "-camera.json"), JsonUtility.ToJson(facts, true));
            if(phoneStart!=0 || runtimeAvatar!=null)
            {
                object display=AvatarType("AvatarDeskWorkDisplay").GetMethod("Ensure").Invoke(null,new[]{desk});
                Assert.That(display,Is.Not.Null);
                try
                {
                    Call(display,"SetWorking",true);Call(display,"Advance",15.1f);
                    AvatarDeskContactEvidence.CaptureFromCamera(actor,camera,Path.Combine(output,
                        (runtimeAvatar!=null?"Joy-runtime":facts.model)+"-actual-phone-camera-"+phoneStart+".png"));
                }
                finally { Call(display,"Dispose"); }
            }
            Assert.That(facts.actualInsideRoom, Is.True, "The desk camera must keep the actual room collision policy.");
            Assert.That(Vector3.Dot(current - head.position, seat.forward), Is.LessThan(-.15f),
                "The actual Home safety route must preserve the rear desk view, rather than leave its old front closeup.");
            Assert.That(current.y, Is.GreaterThan(head.position.y + .15f));
            Assert.That(camera.transform.forward.y, Is.LessThan(-.15f), "The view must look down at the workspace, not up at the ceiling.");
            foreach (Vector3 point in new[] { head.position, seat.position + Vector3.up * .1f, surface.position,
                animator.GetBoneTransform(HumanBodyBones.LeftHand).position, animator.GetBoneTransform(HumanBodyBones.RightHand).position })
            {
                Vector3 viewport = camera.WorldToViewportPoint(point);
                Assert.That(viewport.z, Is.GreaterThan(camera.nearClipPlane));
                Assert.That(viewport.x, Is.InRange(.01f, .99f));
                Assert.That(viewport.y, Is.InRange(.143f, .83f), "Head, chair, keyboard and both hands must fit the real portrait safe area.");
            }
            // The same monotonic journey must recover after the task releases;
            // otherwise the old desk-side frame crops the now standing actor.
            Assert.That(Call(controller, "EndWorkSession", Session, 16f), Is.EqualTo(true));
            for (float now = 16f; now < 30f; now += 1f / 60f)
            {
                if (phoneStart != 0) animator.Update(1f / 60f);
                Call(controller, "Advance", now, 1f / 60f);
                if (runtimeAvatar != null) runtimeAvatar.Runtime.Process();
            }
            Assert.That(controller.GetType().GetProperty("Phase").GetValue(controller),Is.EqualTo("standing"));
            Assert.That(Vector3.Distance(actor.transform.position,initialRoot),Is.LessThan(.001f));
            Assert.That(Quaternion.Angle(actor.transform.rotation,initialFacing),Is.LessThan(.01f));
            if (phoneStart == 2) camera.transform.position = head.position + new Vector3(-.32f, 0f, .30f);
            if (phoneStart != 0) Call(framing, "SetFramingModeCore", returnMode, true);
            else Call(framing, "SetFramingMode", returnMode);
            for (int frame = 0; frame < 1200; frame++)
            {
                monotonicNow += 1f / 60f;
                Vector3 previous = camera.transform.position;
                Call(framing, "AdvanceOwnedFramingFrame", engineDelta, monotonicNow);
                if (phoneStart == 2)
                {
                    Assert.That((bool)Call(navigation, "ContainsCamera", previous, .08f), Is.True);
                    Assert.That(Vector3.Distance(previous, camera.transform.position), Is.LessThanOrEqualTo(1.4f * Mathf.Max(engineDelta, 1f / 60f) + .002f));
                }
            }
            Assert.That((bool)Call(navigation, "ContainsCamera", camera.transform.position, .08f), Is.True);
            HumanBodyBones lowerBone = returnMode == "head" ? HumanBodyBones.Neck
                : returnMode == "hero_full_body" ? HumanBodyBones.LeftFoot : HumanBodyBones.Chest;
            foreach (Vector3 point in new[] { head.position, animator.GetBoneTransform(lowerBone).position })
            {
                Vector3 viewport = camera.WorldToViewportPoint(point);
                Assert.That(viewport.z, Is.GreaterThan(camera.nearClipPlane));
                Assert.That(viewport.x, Is.InRange(.01f, .99f), "The released task must not leave the standing actor cropped at the left edge.");
                Assert.That(viewport.y, Is.InRange(.143f, .83f));
            }
            object[] boundsArgs = { actor.transform, default(Bounds) };
            Assert.That(AvatarType("FrontFullBodyCamera").GetMethod("TryGetHumanoidBounds", BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic)
                .Invoke(null, boundsArgs), Is.EqualTo(true));
            Bounds body = (Bounds)boundsArgs[1];
            Bounds view = returnMode == "head" ? (Bounds)Call(framing, "CalculateHeadBounds", body, Matrix4x4.identity)
                : returnMode == "upper_body" ? new Bounds(new Vector3(body.center.x, body.max.y - body.size.y * .2f, body.center.z),
                    new Vector3(Mathf.Min(body.size.x, body.size.y * .4f * .55f), body.size.y * .4f, Mathf.Min(body.size.z, body.size.y * .4f * .2f))) : body;
            float viewHeight = camera.WorldToViewportPoint(view.center + Vector3.up * view.extents.y).y
                - camera.WorldToViewportPoint(view.center - Vector3.up * view.extents.y).y;
            Assert.That(viewHeight, Is.GreaterThan(.35f), "The requested head or upper-body view must not silently remain a distant full-body shot.");
            Assert.That(framing.GetType().GetProperty("FramingMode").GetValue(framing), Is.EqualTo(returnMode));
        }
        finally
        {
            if (controller != null) Call(controller, "Reset", true);
            if (runtimeAvatar == null) Object.DestroyImmediate(actor);
            Object.DestroyImmediate(room); Object.DestroyImmediate(cameraObject);
            if (runtimeAvatar == null) EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        }
    }

    [UnityTest]
    public IEnumerator RuntimeVrmPhoneCameraStartReachesTheRearDeskViewAndReturns()
    {
        EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
        Type loader = Type.GetType("Maaso.Avatar.MaasoVrmLoader, Maaso.VrmBridge", true);
        var pending = (Task<Vrm10Instance>)loader.GetMethod("LoadVrm10Async", new[] { typeof(string), typeof(CancellationToken) })
            .Invoke(null, new object[] { Path.GetFullPath("Assets/MaasoAvatar/Models/Default/Joy.vrm"), CancellationToken.None });
        while (!pending.IsCompleted) yield return null;
        if (pending.IsFaulted) throw pending.Exception;
        runtimeAvatar = pending.Result;
        try
        {
            Assert.That(runtimeAvatar.Runtime.ControlRig, Is.Not.Null);
            runtimeAvatar.UpdateType = Vrm10Instance.UpdateTypes.None;
            PublishedHomeDeskCameraEndsBehindAndAboveTheSeatedAvatarWithItsWorkspaceVisible(.033288f, "upper_body", false, 3);
        }
        finally
        {
            if (runtimeAvatar != null)
            {
                if (runtimeAvatar.Runtime.ControlRig != null)
                {
                    Object.DestroyImmediate(runtimeAvatar.Runtime.ControlRig.ControlRigAnimator.avatar);
                    Transform controls = runtimeAvatar.transform.Find("Runtime Control Rig");
                    if (controls != null) Object.DestroyImmediate(controls.gameObject);
                }
                Object.DestroyImmediate(runtimeAvatar.gameObject); runtimeAvatar = null;
            }
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        }
    }

    [Serializable] private sealed class Facts
    {
        public string model;
        public Vector3 cameraPosition, cameraForward, desiredPosition, headPosition, seatPosition, deskPosition, seatForward, solvedPosition, goalPosition, subjectCenter, subjectSize, startPosition;
        public Quaternion cameraRotation;
        public float fieldOfView;
        public bool desiredInsideRoom, actualInsideRoom;
        public bool startInRoom, startInsideSubject;
        public int phoneStart;
        public bool solverSucceeded;
        public int pathCount, waypoint;
    }
}

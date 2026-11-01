using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Text.RegularExpressions;
using Newtonsoft.Json.Linq;
using NUnit.Framework;
using UniVRM10;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.TestTools;
using Object = UnityEngine.Object;

/// <summary>Real Companion scene and real Joy skeleton. A tap must finish
/// its visible return within the budget without retiring a newer gaze owner.</summary>
public sealed class HomeScreenTapAttentionTests
{
    [TestCase("Joy", 0)]
    [TestCase("Joy", 1600)]
    [TestCase("Joy", 60000)]


    public void HomeTapReturnsSmoothlyWithinFiveSecondsWithoutChangingBodyState(string model, int duration)
    {
        using var f = new Fixture(model);
        Quaternion head = f.Head.rotation, actor = f.Root.rotation;
        Vector3 position = f.Root.position;
        int state = f.Animator.GetCurrentAnimatorStateInfo(0).fullPathHash;
        float heldUntil = f.Get<float>("actionPoseHoldUntil");
        f.Tap(1f, .2f, duration);
        float start = f.Get<float>("gazeTransitionStartedAt");
        float release = f.Get<float>("screenTapGazeReleaseAt");
        float returned = f.Get<float>("screenTapGazeReturnBy");
        Assert.That(release - start, Is.GreaterThan(0f));
        Assert.That(returned - start, Is.LessThanOrEqualTo(5.001f), "Budget includes the visible return.");
        f.FrameAt(start + .6f);
        float peak = Quaternion.Angle(head, f.Head.rotation);
        Assert.That(peak, Is.GreaterThan(3f), "The actual head must visibly attend the tap.");
        Assert.That(f.Animator.GetCurrentAnimatorStateInfo(0).fullPathHash, Is.EqualTo(state));
        Assert.That(f.Animator.IsInTransition(0), Is.False, "A Home tap cannot queue a whole-body look-around clip.");
        Assert.That(f.Get<float>("actionPoseHoldUntil"), Is.EqualTo(heldUntil));
        f.FrameAt(release + .001f);
        f.FrameAt((release + returned) * .5f);
        float midway = Quaternion.Angle(head, f.Head.rotation);
        Assert.That(midway, Is.GreaterThan(.1f), "Returning must not snap directly to center.");
        Assert.That(midway, Is.LessThan(peak), "The head must already move back before the return deadline.");
        f.FrameAt(returned + .001f);
        Assert.That(f.Get<bool>("gazeActive"), Is.False);
        Assert.That(f.Get<float>("screenTapGazeReturnBy"), Is.LessThan(0f));
        Assert.That(Quaternion.Angle(head, f.Head.rotation), Is.LessThan(.05f));
        Assert.That(Quaternion.Angle(actor, f.Root.rotation), Is.LessThan(.01f));
        Assert.That(Vector3.Distance(position, f.Root.position), Is.LessThan(.00001f));
        if (f.Vrm != null)
        {
            Assert.That(f.Vrm.Runtime.LookAt.Yaw, Is.Zero.Within(.001f));
            Assert.That(f.Vrm.Runtime.LookAt.Pitch, Is.EqualTo(-22.5f).Within(.001f),
                "Return means the existing Home eye-contact center, not the old tap direction.");
        }
    }

    [TestCase("Joy")]

    public void NewTapRenewsAttentionAndTheOldDeadlineCannotClearIt(string model)
    {
        using var f = new Fixture(model);
        f.Tap(0f, .2f, 100);
        float oldDeadline = f.Get<float>("screenTapGazeReturnBy");
        f.Tap(1f, .2f, 1600);
        float newRelease = f.Get<float>("screenTapGazeReleaseAt");
        float newDeadline = f.Get<float>("screenTapGazeReturnBy");
        Assert.That(newDeadline - oldDeadline, Is.GreaterThan(1f));
        f.FrameAt(oldDeadline + .01f);
        Assert.That(f.Get<bool>("gazeActive"), Is.True);
        Assert.That(f.Axis("currentGaze", "headX"), Is.GreaterThan(.35f));
        Assert.That(f.Get<float>("screenTapGazeReleaseAt"), Is.EqualTo(newRelease));
        f.FrameAt(newRelease + .001f);
        f.FrameAt(newDeadline + .001f);
        Assert.That(f.Get<bool>("gazeActive"), Is.False);
    }

    [TestCase("Joy")]

    public void NewExplicitGazeSurvivesThePreviousTapDeadline(string model)
    {
        using var f = new Fixture(model);
        f.Tap(1f, .2f);
        float previousDeadline = f.Get<float>("screenTapGazeReturnBy");
        f.Send("setGaze", new JObject { ["eyeX"] = -.7f, ["headX"] = -.6f, ["eyeY"] = .4f });
        Assert.That(f.Get<float>("screenTapGazeReturnBy"), Is.LessThan(0f));
        f.FrameAt(previousDeadline + 3f);
        Assert.That(f.Get<bool>("gazeActive"), Is.True);
        Assert.That(f.Axis("currentGaze", "headX"), Is.EqualTo(-.6f).Within(.001f));
        Assert.That(f.Axis("currentGaze", "eyeX"), Is.EqualTo(-.7f).Within(.001f));
        Assert.That(f.Get<bool>("gazeReleasing"), Is.False);
    }

    [TestCase("clear")]
    [TestCase("disable")]
    [TestCase("pause")]
    [TestCase("hidden")]
    [TestCase("worldLease")]
    [TestCase("worldLocomotion")]
    [TestCase("worldCamera")]
    [TestCase("phone")]
    [TestCase("task")]
    [TestCase("modelReplacement")]
    [TestCase("accountReset")]
    public void PresentationTakeoverRetiresOnlyTheOldTap(string owner)
    {
        using var f = new Fixture("Joy");
        f.Tap(1f, .2f);
        float takeoverFrame = f.Get<float>("gazeTransitionStartedAt") + .6f;
        float previousDeadline = f.Get<float>("screenTapGazeReturnBy");
        f.Takeover(owner);
        Assert.That(takeoverFrame, Is.LessThan(previousDeadline), "Check owner takeover before ordinary expiry could hide a bug.");
        f.FrameAt(takeoverFrame);
        Assert.That(f.Get<float>("screenTapGazeReturnBy"), Is.LessThan(0f), owner);
        Assert.That(f.Get<bool>("gazeActive"), Is.False, owner);
        if (owner == "phone") Assert.That(f.PhoneOwnsHands, Is.True, "Tap cleanup must not clear the phone owner.");
        if (owner == "task") Assert.That(f.FurnitureActive, Is.True, "Tap cleanup must not cancel the work task.");
    }

    [TestCase("phone")]
    [TestCase("task")]
    [TestCase("worldLease")]
    [TestCase("worldLocomotion")]
    [TestCase("hidden")]
    [TestCase("pause")]
    public void TapsCannotAcquireAttentionFromAnExistingPresentationOwner(string owner)
    {
        using var f = new Fixture("Joy");
        f.Takeover(owner);
        f.Tap(1f, .2f);
        Assert.That(f.Get<float>("screenTapGazeReturnBy"), Is.LessThan(0f), owner);
        Assert.That(f.Get<bool>("gazeActive"), Is.False, owner);
        if (owner == "phone") Assert.That(f.PhoneOwnsHands, Is.True);
        if (owner == "task") Assert.That(f.FurnitureActive, Is.True);
    }

    private const BindingFlags Flags = BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public;
    private static object Call(object target, string name, params object[] args)
    {
        MethodInfo method = target.GetType().GetMethods(Flags)
            .Single(candidate => candidate.Name == name && candidate.GetParameters().Length == args.Length);
        try { return method.Invoke(target, args); }
        catch (TargetInvocationException error) { throw error.InnerException ?? error; }
    }

    private sealed class Fixture : IDisposable
    {
        public readonly Component Receiver;
        public Transform Root { get; private set; }
        public Animator Animator { get; private set; }
        public Transform Head => Animator.GetBoneTransform(HumanBodyBones.Head);
        public Vrm10Instance Vrm => Root.GetComponentInChildren<Vrm10Instance>(true);
        private Behaviour Framing => Camera.main.GetComponent(Type.GetType("Maaso.Avatar.FrontFullBodyCamera, Assembly-CSharp", true)) as Behaviour;
        private readonly List<JObject> receipts = new();
        private readonly long utc = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        private float lastFrame = -1f;
        public bool PhoneOwnsHands => (bool)Get<object>("phoneInteraction").GetType().GetProperty("OwnsHands").GetValue(Get<object>("phoneInteraction"));
        public bool FurnitureActive => (bool)Get<object>("furniturePose").GetType().GetProperty("Active").GetValue(Get<object>("furniturePose"));

        public Fixture(string model)
        {
            EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
            Receiver = Object.FindAnyObjectByType(Type.GetType("Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp", true)) as Component;
            Transform initial = Object.FindAnyObjectByType<Vrm10Instance>().transform;
            foreach (Renderer renderer in initial.GetComponentsInChildren<Renderer>())
                if (renderer is SkinnedMeshRenderer || renderer is MeshRenderer)
                    foreach (Material material in renderer.sharedMaterials)
                        LogAssert.Expect(LogType.Error, new Regex("Instantiating material due to calling renderer\\.material"));
            Application.logMessageReceived += Receive;
            Call(Receiver, "Awake");
            Load(model, "attention-initial");
            Send("setLocalAvatarVisible", new JObject { ["visible"] = true });
            Animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            Animator.applyRootMotion = false;
            Animator.Rebind();
            Animator.Play("idle_shrug", 0, 0f);
            Animator.Update(0f);
            Set("autoBlink", false);
            Set("actionPoseHoldUntil", Time.realtimeSinceStartup + 3600f);
            Send("setExpression", new JObject { ["eyeOpen"] = 1f });
            Call(Receiver, "UpdateExpressionTransition", Get<float>("expressionTransitionStartedAt") + 1f);
            FrameAt(Time.realtimeSinceStartup);
            Assert.That(Call(Receiver, "HasHomeGazePresentation"), Is.True, "Fixture must exercise the actual Home route.");
        }

        private void Receive(string message, string stack, LogType type)
        {
            const string prefix = "[UnityAvatar] command result ";
            if (message.StartsWith(prefix, StringComparison.Ordinal)) receipts.Add(JObject.Parse(message.Substring(prefix.Length)));
        }

        private void Load(string model, string request)
        {
            var command = new JObject { ["requestId"] = request, ["modelUrl"] = "unity://masso/avatar_agent" };

            Send("loadAvatar", command);
            JObject receipt = receipts.LastOrDefault(item => (string)item["requestId"] == request);
            Assert.That(receipt, Is.Not.Null, "Real load must complete.");
            Assert.That((bool)receipt["ok"], Is.True, receipt.ToString());
            Root = (Transform)Receiver.GetType().GetProperty("ActiveAvatarRoot").GetValue(Receiver);
            Animator = Root.GetComponentInChildren<Animator>(true);
        }

        public void Tap(float x, float y, int duration = 1600) => Send("reactToScreenTap",
            new JObject { ["x"] = x, ["y"] = y, ["durationMs"] = duration });
        public void Send(string method, JObject json) => Call(Receiver, "OnFlutterCommand",
            new JObject { ["method"] = method, ["json"] = json.ToString() }.ToString());
        public T Get<T>(string name) => (T)Receiver.GetType().GetField(name, Flags).GetValue(Receiver);
        public void Set(string name, object value) => Receiver.GetType().GetField(name, Flags).SetValue(Receiver, value);
        public float Axis(string state, string axis)
        {
            object value = Get<object>(state);
            return (float)value.GetType().GetField(axis, Flags).GetValue(value);
        }
        public void FrameAt(float now)
        {
            Assert.That(now, Is.GreaterThanOrEqualTo(lastFrame), "Do not rewind the replay clock between frames.");
            lastFrame = now;
            Call(Receiver, "Update");
            Animator.Update(0f);
            Call(Receiver, "AdvancePresentationFrame", now, utc);
            Vrm?.Runtime.Process();
        }
        public void Takeover(string owner)
        {
            switch (owner)
            {
                case "clear": Send("clearGaze", new JObject()); break;
                case "disable": Call(Receiver, "OnDisable"); break;
                case "pause": Call(Receiver, "OnApplicationPause", true); break;
                case "hidden": Send("setLocalAvatarVisible", new JObject { ["visible"] = false }); break;
                case "worldLease": Set("avatarLeasedToWorld", true); break;
                case "worldLocomotion": Set("worldLocomotionActive", true); break;
                case "worldCamera": Framing.enabled = false; break;
                case "phone":
                    Send("setPhoneInteraction", new JObject { ["requestId"] = "attention-phone", ["interactionId"] = "attention-phone",
                        ["phase"] = "reading", ["sequence"] = 1, ["expiresAtMs"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 5000 });
                    Assert.That(PhoneOwnsHands, Is.True, "Production phone command must own presentation.");
                    break;
                case "task":
                    Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));
                    Assert.That(Call(Receiver, "BeginBackgroundWork", new string('a', 64)), Is.True,
                        "Use the real furniture work-session admission.");
                    Assert.That(FurnitureActive, Is.True);
                    break;
                case "modelReplacement": Load("Joy", "attention-replacement"); break;
                case "accountReset": Assert.That(Call(Receiver, "ResetAvatarArbiterState"), Is.EqualTo(true)); break;
                default: throw new ArgumentOutOfRangeException(nameof(owner));
            }
        }
        public void Dispose()
        {
            Application.logMessageReceived -= Receive;
            Set("avatarLeasedToWorld", false);
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        }
    }
}

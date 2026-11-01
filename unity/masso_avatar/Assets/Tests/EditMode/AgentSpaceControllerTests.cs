using System;
using System.Collections.Generic;
using System.Linq.Expressions;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using Newtonsoft.Json.Linq;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.Rendering;
using Object = UnityEngine.Object;

public sealed class AgentSpaceControllerTests
{
    [Test]
    public void PrivatePortraitTransitionPreservesTheHomeStrengthAndDoesNotEndBeforeFadeOut()
    {
        using var fixture = new Fixture();
        fixture.Visible(true);
        fixture.FrameHome();
        Component portrait = fixture.AddPortrait();
        fixture.ExecuteAsync("enterAgentSpace", "portrait-room", "entry", true, 0f, 0f);
        Assert.That(fixture.PortraitStrength(portrait), Is.EqualTo(1f).Within(.002f), "First entry frame keeps Home blur.");
        fixture.AdvanceEntryAt(.4f);
        Assert.That(fixture.PortraitStrength(portrait), Is.InRange(.1f, .95f));
        Assert.That(fixture.HasReceipt("entry"), Is.False);
        fixture.AdvanceEntry();
        Assert.That(fixture.PortraitStrength(portrait), Is.Zero);
        Assert.That(fixture.Receipt("entry")["ok"].Value<bool>(), Is.True);
        fixture.ExecuteAsync("leaveAgentSpace", "portrait-room", "exit", true);
        fixture.AdvanceExit(.4f);
        Assert.That(fixture.PortraitStrength(portrait), Is.InRange(.01f, .99f));
        fixture.AdvanceExit(4f);
        Assert.That(fixture.PortraitStrength(portrait), Is.EqualTo(1f));
        Assert.That(fixture.Receipt("exit")["ok"].Value<bool>(), Is.True);
    }

    [TestCase("transparent")]
    [TestCase("orthographic")]
    [TestCase("disabled")]
    [TestCase("wrong-target")]
    [TestCase("director-disabled")]
    public void PrivatePortraitTransitionCannotEnableAnExcludedCamera(string excluded)
    {
        using var fixture = new Fixture();
        fixture.Visible(true);
        fixture.FrameHome();
        Component portrait = fixture.AddPortrait();
        fixture.ExecuteAsync("enterAgentSpace", "excluded-room", "entry", true);
        Camera camera = fixture.CameraObject.GetComponent<Camera>();
        if (excluded == "transparent") { camera.clearFlags = CameraClearFlags.SolidColor; camera.backgroundColor = Color.clear; }
        else if (excluded == "orthographic") camera.orthographic = true;
        else if (excluded == "disabled") ((Behaviour)portrait).enabled = false;
        else if (excluded == "wrong-target") portrait.GetType().GetProperty("FocusTarget").SetValue(portrait, fixture.Room.transform);
        else fixture.DisableCameraDirector();
        Assert.That(portrait.GetType().GetProperty("CanRender").GetValue(portrait), Is.False);
        Assert.That(fixture.PortraitStrength(portrait), Is.Zero);
    }

    [Test]
    public void RenderedPrivatePortraitHasNoFirstFrameCutAndHalfStrengthReallyBlendsGpuPixels()
    {
        if (SystemInfo.graphicsDeviceType == GraphicsDeviceType.Null)
            Assert.Ignore("The portrait blend contract requires a graphics device.");
        using var fixture = new Fixture();
        fixture.Visible(true);
        fixture.FrameHome();
        Component portrait = fixture.AddPortrait();
        fixture.ExecuteAsync("enterAgentSpace", "portrait-pixels", "entry", true);
        Texture2D raw = null, full = null, half = null, zero = null;
        try
        {
            ((Behaviour)portrait).enabled = false;
            raw = fixture.CaptureFrame();
            ((Behaviour)portrait).enabled = true;
            full = fixture.CaptureFrame();
            fixture.AdvancePortraitOnly(.6f);
            Assert.That(fixture.PortraitStrength(portrait), Is.EqualTo(.5f).Within(.002f));
            half = fixture.CaptureFrame();
            fixture.AdvancePortraitOnly(1.2f);
            Assert.That(fixture.PortraitStrength(portrait), Is.Zero);
            zero = fixture.CaptureFrame();
            Color[] original = raw.GetPixels(), blurred = full.GetPixels(), partial = half.GetPixels(), clear = zero.GetPixels();
            float blendError = 0f, zeroError = 0f, effectDifference = 0f;
            for (int index = 0; index < original.Length; index++)
            {
                Color expected = Color.Lerp(original[index], blurred[index], .5f);
                blendError += ColorDistance(partial[index], expected);
                zeroError += ColorDistance(clear[index], original[index]);
                effectDifference += ColorDistance(blurred[index], original[index]);
                Assert.That(partial[index].a, Is.EqualTo(original[index].a).Within(.01f));
            }
            Assert.That(effectDifference / original.Length, Is.GreaterThan(.0001f), "The real room must exercise visible background blur.");
            Assert.That(blendError / original.Length, Is.LessThan(.01f), "Half strength must blend actual shader output, not toggle the pass.");
            Assert.That(zeroError / original.Length, Is.LessThan(.002f), "Zero strength returns the unchanged camera image.");
        }
        finally
        {
            Object.DestroyImmediate(raw); Object.DestroyImmediate(full);
            Object.DestroyImmediate(half); Object.DestroyImmediate(zero);
        }
    }

    private static float ColorDistance(Color left, Color right) =>
        Mathf.Abs(left.r - right.r) + Mathf.Abs(left.g - right.g) + Mathf.Abs(left.b - right.b);
    [Test]
    public void AnimatedEntryKeepsTheFirstHomeImageAndReceivesItsReceiptOnlyWhenActive()
    {
        using var fixture = new Fixture();
        fixture.Visible(true);
        fixture.FrameHome();
        var home = fixture.ReadProjection();
        Vector3 avatarPosition = fixture.Actor.transform.position;
        Quaternion avatarRotation = fixture.Actor.transform.rotation;
        fixture.ExecuteAsync("enterAgentSpace", "smooth-room", "entry", true);
        Assert.That(fixture.Receipts, Is.Empty, "Entry must not acknowledge an unfinished camera route.");
        fixture.AssertProjection(home, "first entry frame");
        Assert.That(fixture.Actor.transform.position, Is.EqualTo(avatarPosition));
        Assert.That(Quaternion.Angle(fixture.Actor.transform.rotation, avatarRotation), Is.LessThan(.01f));
        fixture.ExecuteAsync("requestAgentSpaceMoveAtScreenPoint", "smooth-room", "early-move", false);
        Assert.That(fixture.Receipts[0]["code"].Value<string>(), Is.EqualTo("space_busy"));
        fixture.AdvanceEntry();
        Assert.That(fixture.Receipt("entry")["ok"].Value<bool>(), Is.True);
        Assert.That(fixture.CameraPhase, Is.EqualTo("Active"));
    }

    [Test]
    public void AnimatedExitHoldsTheSameOwnerAndFirstImageUntilTheReturnHasFinished()
    {
        using var fixture = new Fixture();
        fixture.Visible(true);
        fixture.FrameHome();
        fixture.ExecuteAsync("enterAgentSpace", "smooth-exit", "entry", true);
        fixture.AdvanceEntry();
        fixture.MoveOwnerAwayFromHome();
        var world = fixture.ReadProjection();
        fixture.ExecuteAsync("leaveAgentSpace", "smooth-exit", "exit", true, .12f, .2f);
        Assert.That(fixture.HasReceipt("exit"), Is.False);
        Assert.That(fixture.Actor.transform.parent.name, Is.EqualTo("AgentSpaceOwner"));
        Assert.That(((Behaviour)fixture.Framing).enabled, Is.False);
        fixture.AssertProjection(world, "first exit frame");
        fixture.AdvanceExit(.5f);
        Assert.That(fixture.HasReceipt("exit"), Is.False);
        Assert.That(fixture.Actor.transform.parent.name, Is.EqualTo("AgentSpaceOwner"));
        fixture.AdvanceExit(1.01f);
        Assert.That(fixture.Receipt("exit")["ok"].Value<bool>(), Is.True);
        Assert.That(fixture.Actor.transform.parent, Is.SameAs(fixture.Host.transform));
        Assert.That(((Behaviour)fixture.Framing).enabled, Is.True);
        var final = fixture.ReadProjection();
        fixture.AdvanceHome();
        fixture.AssertProjection(final, "first ordinary Home frame");
    }

    [Test]
    public void ReturningHomeProtectsLegacyBodyAndCameraButKeepsSpeechFaceAndViewportLive()
    {
        using var fixture = new Fixture();
        fixture.Visible(true);
        fixture.FrameHome();
        fixture.ExecuteAsync("enterAgentSpace", "return-chat", "entry", true);
        fixture.AdvanceEntry();
        fixture.MoveOwnerAwayFromHome();
        fixture.ExecuteAsync("leaveAgentSpace", "return-chat", "exit", true, .12f, .2f);
        Assert.That(fixture.IsReturningHome, Is.True);
        Vector3 position = fixture.Actor.transform.position;
        Quaternion rotation = fixture.Actor.transform.rotation;
        var camera = fixture.ReadProjection();
        string framing = fixture.FramingMode;
        fixture.Send("setBodyPose", new JObject { ["x"] = 3, ["yaw"] = 90, ["scale"] = 2 });
        fixture.Send("reactToScreenTap", new JObject { ["normalizedX"] = .1, ["normalizedY"] = .8 });
        fixture.Send("playPrimitive", new JObject { ["type"] = "jump" });
        fixture.Send("setFraming", new JObject { ["mode"] = "upper_body" });
        fixture.Send("setWorldCamera", new JObject { ["mode"] = "upper_body" });
        Assert.That(fixture.Actor.transform.position, Is.EqualTo(position));
        Assert.That(Quaternion.Angle(fixture.Actor.transform.rotation, rotation), Is.LessThan(.01f));
        fixture.AssertProjection(camera, "return owns the camera during ordinary chat commands");
        Assert.That(fixture.FramingMode, Is.EqualTo(framing));
        fixture.Send("setMouthOpen", new JObject { ["value"] = .5 });
        fixture.Send("setExpression", new JObject { ["happy"] = .65 });
        fixture.Send("setViewportSafeArea", new JObject { ["top"] = .07, ["bottom"] = .21 });
        Assert.That(fixture.ReceiverField<float>("mouthOpen"), Is.EqualTo(.5f).Within(.001f));
        Assert.That(fixture.ExpressionTarget("happy"), Is.EqualTo(.65f).Within(.001f));
        Assert.That(fixture.FramingField<float>("topSafeViewport"), Is.EqualTo(.07f).Within(.001f));
        Assert.That(fixture.FramingField<float>("bottomSafeViewport"), Is.EqualTo(.21f).Within(.001f));
        fixture.AssertProjection(camera, "safe viewport metadata cannot move the disabled Home lens");
        Assert.That(fixture.IsReturningHome, Is.True);
        Assert.That(fixture.HasReceipt("exit"), Is.False);
        fixture.AdvanceExit(4f);
        fixture.AssertSuccessful("exit");
        Assert.That(fixture.IsReturningHome, Is.False);
        fixture.Send("setFraming", new JObject { ["mode"] = "upper_body" });
        Assert.That(fixture.FramingMode, Is.EqualTo("upper_body"));
    }

    [Test]
    public void ReturningHomeConsumesValidatedBodyAndFramingTicketsWithoutMutatingOrForcingReset()
    {
        using var fixture = new Fixture();
        fixture.Visible(true);
        fixture.FrameHome();
        fixture.ExecuteAsync("enterAgentSpace", "return-ticket", "entry", true);
        fixture.AdvanceEntry();
        fixture.MoveOwnerAwayFromHome();
        fixture.ExecuteAsync("leaveAgentSpace", "return-ticket", "exit", true);
        Vector3 position = fixture.Actor.transform.position;
        var camera = fixture.ReadProjection();
        string framing = fixture.FramingMode;
        foreach (string channel in new[] { "bodyGesture", "framing" })
        {
            JObject payload = channel == "bodyGesture"
                ? new JObject { ["channel"] = channel, ["gesture"] = "jump" }
                : new JObject { ["channel"] = channel, ["mode"] = "upper_body" };
            JObject accepted = fixture.SendArbiter(ArbiterCommand(channel, payload, 1));
            Assert.That(accepted["ok"].Value<bool>(), Is.True, accepted.ToString());
            Assert.That(fixture.IsReturningHome, Is.True);
            Assert.That(fixture.Actor.transform.position, Is.EqualTo(position));
            fixture.AssertProjection(camera, "validated ticket cannot replace the scene return");
            Assert.That(fixture.FramingMode, Is.EqualTo(framing));
            JObject clear = fixture.SendArbiter(ArbiterCommand(channel,
                new JObject { ["channel"] = channel, ["clear"] = true }, 2, true));
            Assert.That(clear["ok"].Value<bool>(), Is.True);
            JObject stale = fixture.SendArbiter(ArbiterCommand(channel, payload, 1));
            Assert.That(stale["code"].Value<string>(), Is.EqualTo("stale_ticket"));
        }
        fixture.Send("setMouthOpen", new JObject { ["value"] = .4 });
        Assert.That(fixture.ReceiverField<float>("mouthOpen"), Is.EqualTo(.4f).Within(.001f));
        Assert.That(fixture.IsReturningHome, Is.True);
        Assert.That(fixture.HasReceipt("exit"), Is.False);
        fixture.AdvanceExit(4f);
        fixture.AssertSuccessful("exit");
        Assert.That(fixture.IsReturningHome, Is.False);
    }

    [Test]
    public void HidingTheLocalAvatarStillCancelsAProtectedHomeReturn()
    {
        using var fixture = new Fixture();
        fixture.Visible(true);
        fixture.FrameHome();
        fixture.ExecuteAsync("enterAgentSpace", "return-hide", "entry", true);
        fixture.AdvanceEntry();
        fixture.MoveOwnerAwayFromHome();
        fixture.ExecuteAsync("leaveAgentSpace", "return-hide", "exit", true);
        Assert.That(fixture.IsReturningHome, Is.True);
        fixture.Visible(false);
        Assert.That(fixture.IsReturningHome, Is.False);
        Assert.That(fixture.Receipt("exit")["code"].Value<string>(), Is.EqualTo("space_transition_cancelled"));
        Assert.That(fixture.Actor.transform.parent, Is.SameAs(fixture.Host.transform));
    }

    private static JObject ArbiterCommand(string channel, JObject payload, long ticket, bool clear = false)
    {
        string json = payload.ToString(Newtonsoft.Json.Formatting.None);
        using SHA256 algorithm = SHA256.Create();
        string digest = BitConverter.ToString(algorithm.ComputeHash(Encoding.UTF8.GetBytes(json)))
            .Replace("-", string.Empty).ToLowerInvariant();
        return new JObject {
            ["protocolVersion"] = 1, ["requestId"] = "return-" + channel + "-" + ticket,
            ["ticket"] = ticket, ["rendererId"] = "return-renderer",
            ["ownerToken"] = new string('A', 43), ["commitToken"] = new string('C', 43),
            ["accountGeneration"] = 7, ["rendererGeneration"] = 1, ["channel"] = channel,
            ["fingerprint"] = clear ? string.Empty : "0123456789abcdef",
            ["payloadJson"] = json, ["payloadSha256"] = digest,
            ["deadlineEpochMs"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 4000,
            ["clearsChannel"] = clear,
        };
    }

    [Test]
    public void ImmediateExitCancelsAnInFlightAnimatedExitWithoutWaitingForItsClock()
    {
        using var fixture = new Fixture();
        fixture.Visible(true);
        fixture.FrameHome();
        fixture.ExecuteAsync("enterAgentSpace", "strict-exit", "entry", true);
        fixture.AdvanceEntry();
        fixture.ExecuteAsync("leaveAgentSpace", "strict-exit", "normal-exit", true);
        fixture.ExecuteAsync("leaveAgentSpace", "strict-exit", "strict-exit", false);
        Assert.That(fixture.Receipt("normal-exit")["code"].Value<string>(), Is.EqualTo("space_transition_cancelled"));
        Assert.That(fixture.Receipt("strict-exit")["ok"].Value<bool>(), Is.True);
        Assert.That(fixture.CameraPhase, Is.EqualTo("Home"));
        Assert.That(fixture.Actor.transform.parent, Is.SameAs(fixture.Host.transform));
        fixture.AdvanceExit(3f);
        Assert.That(fixture.Receipts.FindAll(value => value["requestId"].Value<string>() == "normal-exit").Count, Is.EqualTo(1));
    }

    [Test]
    public void LeavingDuringEntryCancelsTheEntryAndDuplicateExitsJoinTheSameReturn()
    {
        using var fixture = new Fixture();
        fixture.Visible(true);
        fixture.FrameHome();
        fixture.ExecuteAsync("enterAgentSpace", "cancel-entry", "entry", true);
        fixture.ExecuteAsync("leaveAgentSpace", "cancel-entry", "exit-one", true);
        float started = fixture.ExitStarted;
        fixture.ExecuteAsync("leaveAgentSpace", "cancel-entry", "exit-two", true);
        Assert.That(fixture.Receipt("entry")["code"].Value<string>(), Is.EqualTo("space_transition_cancelled"));
        Assert.That(fixture.ExitStarted, Is.EqualTo(started));
        Assert.That(fixture.HasReceipt("exit-one"), Is.False);
        fixture.AdvanceExit(1.01f);
        Assert.That(fixture.Receipt("exit-one")["ok"].Value<bool>(), Is.True);
        Assert.That(fixture.Receipt("exit-two")["ok"].Value<bool>(), Is.True);
        Assert.That(fixture.Execute("enterAgentSpace", "cancel-entry")["code"].Value<string>(), Is.EqualTo("session_retired"));
    }

    [TestCase(.1f, -1f)]
    [TestCase(float.PositiveInfinity, .1f)]
    [TestCase(.5f, .1f)]
    public void InvalidViewportCannotStartAnAnimatedSession(float top, float bottom)
    {
        using var fixture = new Fixture();
        fixture.Visible(true);
        fixture.ExecuteAsync("enterAgentSpace", "bad-viewport", "invalid", true, top, bottom);
        Assert.That(fixture.Receipt("invalid")["code"].Value<string>(), Is.EqualTo("invalid_request"));
        Assert.That(fixture.Actor.transform.parent, Is.SameAs(fixture.Host.transform));
    }

    [Test]
    public void RendererDisableRetiresTheSessionAndCannotProduceALateSuccessfulEntry()
    {
        using var fixture = new Fixture();
        fixture.Visible(true);
        fixture.FrameHome();
        fixture.ExecuteAsync("enterAgentSpace", "disabled-entry", "entry", true);
        ((Behaviour)fixture.Controller).enabled = false;
        fixture.DisableController();
        Assert.That(fixture.Receipt("entry")["code"].Value<string>(), Is.EqualTo("space_transition_cancelled"));
        Assert.That(fixture.Actor.transform.parent, Is.SameAs(fixture.Host.transform));
        fixture.AdvanceEntry();
        Assert.That(fixture.Receipts.Count, Is.EqualTo(1));
        Assert.That(fixture.Execute("enterAgentSpace", "disabled-entry")["code"].Value<string>(), Is.EqualTo("session_retired"));
    }

    [Test]
    public void LegacyPacketDoesNotAcquireAViewportOrAnAnimation()
    {
        Type commandType = Type.GetType("Maaso.Avatar.AgentSpaceCommand, Assembly-CSharp", true);
        Type controllerType = Type.GetType("Maaso.Avatar.AgentSpaceController, Assembly-CSharp", true);
        object command = controllerType.GetMethod("ParseCommand").Invoke(null,
            new object[] { "{\"requestId\":\"legacy\",\"sessionId\":\"legacy-session\"}" });
        Assert.That(commandType.GetField("animated").GetValue(command), Is.False);
        Assert.That(float.IsNaN((float)commandType.GetField("viewportTop").GetValue(command)), Is.True);
        Assert.That(float.IsNaN((float)commandType.GetField("viewportBottom").GetValue(command)), Is.True);
    }

    [Test]
    public void ACompletedSpaceCannotRestoreOrReframeANewerHomePresentation()
    {
        using var fixture = new Fixture();
        fixture.Visible(true);
        fixture.FrameHome();
        fixture.Execute("enterAgentSpace", "retired-space");
        fixture.Execute("leaveAgentSpace", "retired-space");
        fixture.CameraObject.transform.position += Vector3.right;
        fixture.Actor.transform.position += Vector3.right;
        var newer = fixture.ReadProjection();
        Vector3 position = fixture.Actor.transform.position;
        fixture.Controller.GetType().GetMethod("CancelForReset").Invoke(fixture.Controller, Array.Empty<object>());
        fixture.AssertProjection(newer, "retired space reset");
        Assert.That(fixture.Actor.transform.position, Is.EqualTo(position));
    }

    [Test]
    public void ImmediateExitAlsoRestoresTheRequestedHomeViewport()
    {
        using var fixture = new Fixture();
        fixture.Visible(true);
        fixture.FrameHome();
        fixture.ExecuteAsync("enterAgentSpace", "no-motion", "entry", false, 0f, 0f);
        fixture.ExecuteAsync("leaveAgentSpace", "no-motion", "exit", false, .12f, .21f);
        var viewport = (Vector2)fixture.Framing.GetType().GetProperty("ViewportSafeArea").GetValue(fixture.Framing);
        Assert.That(viewport.x, Is.EqualTo(.12f));
        Assert.That(viewport.y, Is.EqualTo(.21f));
        Assert.That(fixture.Receipt("exit")["ok"].Value<bool>(), Is.True);
    }

    [Test]
    public void PersonalRoomKeepsTheSelectedAvatarAndRestoresHomeOnExit()
    {
        using var fixture = new Fixture();
        fixture.Visible(true);
        JObject entered = fixture.Execute("enterAgentSpace", "room:1");
        Assert.That((bool)entered["ok"], Is.True, entered.ToString());
        Assert.That(fixture.ActiveAvatar, Is.SameAs(fixture.Actor.transform));
        Assert.That(fixture.Actor.transform.parent.name, Is.EqualTo("AgentSpaceOwner"));
        Assert.That(fixture.Actor.activeInHierarchy, Is.True);
        Assert.That(fixture.Actor.GetComponent<Renderer>().enabled, Is.True);
        Assert.That((string)entered["sessionId"], Is.EqualTo("room:1"));
        Assert.That((string)entered["method"], Is.EqualTo("enterAgentSpace"));
        Assert.That(fixture.Execute("enterAgentSpace", "room:2")["code"].Value<string>(), Is.EqualTo("space_busy"));
        Assert.That(fixture.Execute("leaveAgentSpace", "other-room")["code"].Value<string>(), Is.EqualTo("session_mismatch"));
        Assert.That(fixture.ActiveAvatar, Is.SameAs(fixture.Actor.transform));
        JObject exited = fixture.Execute("leaveAgentSpace", "room:1");
        Assert.That((bool)exited["ok"], Is.True, exited.ToString());
        Assert.That(fixture.Actor.transform.parent, Is.SameAs(fixture.Host.transform));
        Assert.That(fixture.Framing.GetType().GetProperty("enabled").GetValue(fixture.Framing), Is.True);
        Assert.That(fixture.Execute("enterAgentSpace", "room:1")["code"].Value<string>(), Is.EqualTo("session_retired"));
        Assert.That((bool)fixture.Execute("enterAgentSpace", "room:3")["ok"], Is.True);
    }

    [Test]
    public void MissingAvatarVisibilityIsAnExplicitFailureAndCanRecoverLocally()
    {
        using var fixture = new Fixture();
        fixture.Visible(false);
        JObject denied = fixture.Execute("enterAgentSpace", "room:4");
        Assert.That((bool)denied["ok"], Is.False);
        Assert.That((string)denied["code"], Is.EqualTo("avatar_presentation_unavailable"));
        Assert.That(fixture.Actor.transform.parent, Is.SameAs(fixture.Host.transform));
        fixture.Visible(true);
        Assert.That((bool)fixture.Execute("enterAgentSpace", "room:4")["ok"], Is.True);
        Assert.That(fixture.Actor.GetComponent<Renderer>().enabled, Is.True);
    }

    [Test]
    public void SessionCancellationBeforeEntryCannotBeRevivedByLateEntry()
    {
        using var fixture = new Fixture();
        fixture.Visible(true);
        Assert.That((bool)fixture.Execute("leaveAgentSpace", "cancelled-room")["ok"], Is.True);
        Assert.That((string)fixture.Execute("enterAgentSpace", "cancelled-room")["code"], Is.EqualTo("session_retired"));
        Assert.That((string)fixture.Execute("requestAgentSpaceMoveAtScreenPoint", "cancelled-room")["code"], Is.EqualTo("session_mismatch"));
        Assert.That(fixture.Actor.transform.parent, Is.SameAs(fixture.Host.transform));
    }

    [TestCase("room:1\n")]
    [TestCase("room 1")]
    public void InvalidSessionCannotAcquireTheSelectedAvatar(string session)
    {
        using var fixture = new Fixture();
        fixture.Visible(true);
        Assert.That((string)fixture.Execute("enterAgentSpace", session)["code"], Is.EqualTo("invalid_request"));
        Assert.That(fixture.Actor.transform.parent, Is.SameAs(fixture.Host.transform));
    }

    private sealed class Fixture : IDisposable
    {
        public readonly GameObject Host, Actor, Room, CameraObject;
        public readonly Component Receiver, Controller, Framing;
        public readonly List<JObject> Receipts = new();
        private Component Director => CameraObject.GetComponent(W("WorldCameraDirector"));
        private Component Owner => Actor.transform.parent?.GetComponent(W("WorldOwnerAvatarLease"));
        public string CameraPhase => Director.GetType().GetProperty("Phase").GetValue(Director).ToString();
        public float ExitStarted => Field<float>(Director, "transitionStartedAt");
        private readonly object previousMap;
        private readonly Type mapType = Type.GetType("Maaso.World.PersistentWorldMapController, Assembly-CSharp", true);
        public Transform ActiveAvatar => (Transform)Receiver.GetType().GetProperty("ActiveAvatarRoot").GetValue(Receiver);
        public bool IsReturningHome => (bool)Controller.GetType().GetProperty("IsReturningHome").GetValue(Controller);
        public string FramingMode => (string)Framing.GetType().GetProperty("FramingMode").GetValue(Framing);
        public T ReceiverField<T>(string name) => Field<T>(Receiver, name);
        public T FramingField<T>(string name) => Field<T>(Framing, name);
        public float ExpressionTarget(string name)
        {
            object value = Field<object>(Receiver, "expressionTarget");
            return (float)value.GetType().GetField(name).GetValue(value);
        }
        public void AssertSuccessful(string request) =>
            Assert.That(Receipt(request)["ok"].Value<bool>(), Is.True, Receipt(request).ToString());
        public JObject SendArbiter(JObject body)
        {
            JObject result = null;
            Application.LogCallback capture = (message, _, _) =>
            {
                const string prefix = "[UnityAvatar] command result ";
                if (!message.StartsWith(prefix, StringComparison.Ordinal)) return;
                JObject candidate = JObject.Parse(message.Substring(prefix.Length));
                if (candidate["method"]?.Value<string>() == "avatarArbiterCommand" &&
                    candidate["requestId"]?.Value<string>() == body["requestId"]?.Value<string>()) result = candidate;
            };
            Application.logMessageReceived += capture;
            try { Send("avatarArbiterCommand", body); }
            finally { Application.logMessageReceived -= capture; }
            Assert.That(result, Is.Not.Null, "Every ticket must retain its exact validation receipt.");
            return result;
        }

        public Fixture()
        {
            previousMap = mapType.GetField("current", BindingFlags.Static | BindingFlags.NonPublic).GetValue(null);
            Room = Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));
            Component map = Room.GetComponent(mapType);
            mapType.GetField("current", BindingFlags.Static | BindingFlags.NonPublic).SetValue(null, map);
            Host = new GameObject("PersonalSpaceSelectedAvatarHost");
            Host.SetActive(false);
            Actor = GameObject.CreatePrimitive(PrimitiveType.Capsule);
            Actor.name = "AlreadySelectedAvatar";
            Actor.transform.SetParent(Host.transform, false);
            Actor.transform.position = ((Transform)mapType.GetProperty("HomeAgentAnchor").GetValue(map)).position;
            Receiver = Host.AddComponent(A("UnityAvatarCommandReceiver"));
            Set(Receiver, "avatarRoot", Actor.transform);
            Set(Receiver, "bundledAvatarRoot", Actor.transform);
            Set(map, "avatarReceiver", Receiver);
            CameraObject = new GameObject("PersonalSpaceLocalCamera") { tag = "MainCamera" };
            var camera = CameraObject.AddComponent<Camera>();
            camera.aspect = .5f;
            camera.transform.position = new Vector3(0, 1.3f, 3.2f);
            Framing = CameraObject.AddComponent(A("FrontFullBodyCamera"));
            Framing.GetType().GetProperty("TargetRoot").SetValue(Framing, Actor.transform);
            Framing.GetType().GetMethod("SetHomeViewReference").Invoke(Framing,
                new[] { mapType.GetProperty("HomeCameraReference").GetValue(map) });
            Host.SetActive(true);
            Controller = Host.AddComponent(A("AgentSpaceController"));
            Call(Receiver, "EnsureAgentSpace");
        }

        public void Visible(bool visible) => Receiver.GetType().GetMethod("OnFlutterCommand").Invoke(Receiver,
            new[] { new JObject { ["method"] = "setLocalAvatarVisible", ["json"] = new JObject { ["visible"] = visible }.ToString() }.ToString() });
        public void Send(string method, JObject body) => Receiver.GetType().GetMethod("OnFlutterCommand").Invoke(Receiver,
            new[] { new JObject { ["method"] = method, ["json"] = body.ToString() }.ToString() });
        public void SetReceiverField(string name, object value) => Set(Receiver, name, value);
        public void ResetOldSpace() => Controller.GetType().GetMethod("CancelForReset").Invoke(Controller, Array.Empty<object>());
        public void TickOldSpace() => Call(Controller, "LateUpdate");

        public JObject Execute(string method, string session)
        {
            object command = JsonUtility.FromJson(new JObject
            { ["requestId"] = "request:" + session, ["sessionId"] = session, ["x"] = .5, ["y"] = .5 }.ToString(), A("AgentSpaceCommand"));
            object result = Controller.GetType().GetMethod("Execute").Invoke(Controller, new[] { method, command });
            return JObject.Parse(JsonUtility.ToJson(result));
        }

        public void ExecuteAsync(string method, string session, string request, bool animated,
            float? top = null, float? bottom = null)
        {
            MethodInfo execute = Controller.GetType().GetMethod("ExecuteAsync");
            Assert.That(execute, Is.Not.Null, "Native Agent Space commands require a completion receipt.");
            Type result = A("AgentSpaceResult");
            Type callbackType = typeof(Action<>).MakeGenericType(result);
            ParameterExpression parameter = Expression.Parameter(result, "result");
            var record = typeof(Fixture).GetMethod(nameof(Record), BindingFlags.NonPublic | BindingFlags.Instance);
            Delegate callback = Expression.Lambda(callbackType,
                Expression.Call(Expression.Constant(this), record, Expression.Convert(parameter, typeof(object))), parameter).Compile();
            object command = Activator.CreateInstance(A("AgentSpaceCommand"));
            command.GetType().GetField("requestId").SetValue(command, request);
            command.GetType().GetField("sessionId").SetValue(command, session);
            command.GetType().GetField("animated").SetValue(command, animated);
            if (top.HasValue) command.GetType().GetField("viewportTop").SetValue(command, top.Value);
            if (bottom.HasValue) command.GetType().GetField("viewportBottom").SetValue(command, bottom.Value);
            execute.Invoke(Controller, new[] { method, command, callback });
        }

        private void Record(object result) => Receipts.Add(JObject.Parse(JsonUtility.ToJson(result)));
        public bool HasReceipt(string request) => Receipts.Exists(value => value["requestId"].Value<string>() == request);
        public JObject Receipt(string request)
        {
            JObject receipt = Receipts.Find(value => value["requestId"].Value<string>() == request);
            Assert.That(receipt, Is.Not.Null, "Expected completed receipt " + request);
            return receipt;
        }
        public void FrameHome()
        {
            W("WorldAvatarGrounding").GetMethod("TryGround").Invoke(null,
                new object[] { Actor.transform, 0f, 0f });
            Framing.GetType().GetMethod("FrameNow").Invoke(Framing, Array.Empty<object>());
        }
        public void AdvanceEntry()
        {
            if (Director == null) return;
            for (int frame = 1; frame <= 600 && PhaseField == "Entering"; frame++)
            {
                Set(Director, "transitionStartedAt", Time.realtimeSinceStartup - frame / 60f);
                AdvancePrivateFrame();
            }
            Call(Controller, "LateUpdate");
        }
        public void AdvanceEntryAt(float elapsed)
        {
            Set(Director, "transitionStartedAt", Time.realtimeSinceStartup - elapsed);
            AdvancePrivateFrame();
        }
        public void AdvancePortraitOnly(float elapsed)
        {
            Set(Director, "transitionStartedAt", Time.realtimeSinceStartup - elapsed);
            Set(Director, "privateCameraTick", float.PositiveInfinity);
            Call(Director, "UpdateTransition", Time.realtimeSinceStartup);
        }
        public Texture2D CaptureFrame()
        {
            Camera camera = CameraObject.GetComponent<Camera>();
            RenderTexture savedTarget = camera.targetTexture;
            RenderTexture savedActive = RenderTexture.active;
            var target = new RenderTexture(128, 256, 24, RenderTextureFormat.ARGB32, RenderTextureReadWrite.Linear);
            try
            {
                target.Create(); camera.targetTexture = target;
                camera.Render(); RenderTexture.active = target;
                var pixels = new Texture2D(128, 256, TextureFormat.RGBA32, false, true);
                pixels.ReadPixels(new Rect(0, 0, 128, 256), 0, 0); pixels.Apply();
                return pixels;
            }
            finally
            {
                camera.targetTexture = savedTarget; RenderTexture.active = savedActive;
                target.Release(); Object.DestroyImmediate(target);
            }
        }
        public Component AddPortrait()
        {
            var portrait = CameraObject.AddComponent(A("PortraitDepthOfField"));
            portrait.GetType().GetProperty("FocusTarget").SetValue(portrait, Actor.transform);
            portrait.GetType().GetMethod("UpdateFocus").Invoke(portrait, Array.Empty<object>());
            return portrait;
        }
        public float PortraitStrength(Component portrait)
        {
            PropertyInfo strength = portrait.GetType().GetProperty("RenderStrength");
            Assert.That(strength, Is.Not.Null, "Portrait strength must be scoped to the rendered space transition.");
            return (float)strength.GetValue(portrait);
        }
        public void AdvanceExit(float seconds)
        {
            if (Director == null || PhaseField == "Home") return;
            for (int frame = 1; frame <= 1200 && PhaseField != "Leaving" && PhaseField != "Home"; frame++)
                AdvancePrivateFrame();
            Set(Director, "transitionStartedAt", Time.realtimeSinceStartup - seconds);
            Call(Director, "UpdateTransition", Time.realtimeSinceStartup);
            Call(Controller, "LateUpdate");
        }
        private string PhaseField => Field<object>(Director, "phase").ToString();
        private void AdvancePrivateFrame()
        {
            Component owner = Owner;
            if (owner != null) Call(owner, "AdvanceLocomotion", 1f / 60f);
            Set(Director, "privateCameraTick", Time.realtimeSinceStartup - 1f / 60f);
            Call(Director, "UpdateTransition", Time.realtimeSinceStartup);
            Call(Controller, "LateUpdate");
        }
        public void AdvanceHome() => Framing.GetType().GetMethod("AdvanceFraming").Invoke(Framing, new object[] { 1f / 60f });
        public void DisableController() => Call(Controller, "OnDisable");
        public void DisableCameraDirector() => ((Behaviour)Director).enabled = false;
        public void MoveOwnerAwayFromHome()
        {
            Owner.transform.position += Vector3.left;
            Set(Owner, "targetPosition", Owner.transform.position);
            CameraObject.transform.position += Vector3.left;
        }
        public (Vector3 position, Quaternion rotation, float fov) ReadProjection() =>
            (CameraObject.transform.position, CameraObject.transform.rotation, CameraObject.GetComponent<Camera>().fieldOfView);
        public void AssertProjection((Vector3 position, Quaternion rotation, float fov) expected, string stage)
        {
            var actual = ReadProjection();
            Assert.That(Vector3.Distance(actual.position, expected.position), Is.LessThan(.0002f), stage + " position");
            Assert.That(Quaternion.Angle(actual.rotation, expected.rotation), Is.LessThan(.01f), stage + " rotation");
            Assert.That(actual.fov, Is.EqualTo(expected.fov).Within(.0002f), stage + " lens");
        }

        public void Dispose()
        {
            if (Controller != null)
            {
                string current = (string)Controller.GetType().GetProperty("SessionId").GetValue(Controller);
                if (!string.IsNullOrEmpty(current)) Execute("leaveAgentSpace", current);
            }
            Object.DestroyImmediate(Host);
            Object.DestroyImmediate(CameraObject);
            Object.DestroyImmediate(Room);
            mapType.GetField("current", BindingFlags.Static | BindingFlags.NonPublic).SetValue(null, previousMap);
        }

        private static Type A(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
        private static Type W(string name) => Type.GetType("Maaso.World." + name + ", Assembly-CSharp", true);
        private static T Field<T>(object target, string name) =>
            (T)target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic).GetValue(target);
        private static object Call(object target, string method, params object[] arguments) =>
            target.GetType().GetMethod(method, BindingFlags.Instance | BindingFlags.NonPublic).Invoke(target, arguments);
        private static void Set(object target, string name, object value) =>
            target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic).SetValue(target, value);
    }
}

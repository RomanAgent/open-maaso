using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using Newtonsoft.Json.Linq;
using NUnit.Framework;
using UniVRM10;
using UnityEditor.SceneManagement;
using UnityEditor;
using UnityEngine;
using UnityEngine.TestTools;
using Object = UnityEngine.Object;

public sealed class HostBackgroundTaskWorkTests
{
    private const string Session = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string OtherSession = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    [Test]
    public void PausingAnExplicitDeskPoseAlsoTurnsOffItsScreen()
    {
        using var f = new Fixture();
        Assert.That(f.Call("BeginFurniture", "work_desk"), Is.EqualTo(true));
        f.Advance(0f, 15f);
        object display = f.Field<object>("deskWorkDisplay");
        Assert.That(display, Is.Not.Null);
        Assert.That(display.GetType().GetProperty("IsLit").GetValue(display), Is.EqualTo(true));
        f.Call("OnApplicationPause", true);
        Assert.That(display.GetType().GetProperty("IsLit").GetValue(display), Is.EqualTo(false));
        f.Call("OnApplicationPause", false);
        Assert.That(display.GetType().GetProperty("IsLit").GetValue(display), Is.EqualTo(true));
    }

    [Test]
    public void LateConversationBodyCommandsCannotMoveTheDeskButSpeechCanContinue()
    {
        using var f = new Fixture();
        Assert.That(f.Send(f.Command("start"))["ok"].Value<bool>(), Is.True);
        f.Advance(0f, 15f);
        Vector3 position = f.Actor.position;
        f.Call("OnFlutterCommand", "{\"method\":\"setBodyPose\",\"json\":\"{\\\"x\\\":3,\\\"y\\\":0,\\\"z\\\":0,\\\"scale\\\":1}\"}");
        Assert.That(f.Actor.position, Is.EqualTo(position), "A queued chat pose cannot yank the actor away from the keyboard.");
        f.Call("OnFlutterCommand", "{\"method\":\"setFraming\",\"json\":\"{\\\"mode\\\":\\\"desk_over_shoulder\\\"}\"}");
        Assert.That(f.Actor.position, Is.EqualTo(position), "A repeated work-camera request only controls the camera.");
        f.Call("OnFlutterCommand", "{\"method\":\"setMouthOpen\",\"json\":\"{\\\"value\\\":0.5}\"}");
        Assert.That(f.Field<float>("mouthOpen"), Is.EqualTo(.5f).Within(.001f));
        Assert.That(f.Phase, Is.EqualTo("working"));
        Assert.That(f.Field<string>("hostBackgroundWorkSessionId"), Is.EqualTo(Session));
    }

    [TestCase(0f)]
    [TestCase(15f)]
    public void ComposerPhoneActivityCannotCancelATaskWalkingToOrWorkingAtTheDesk(float elapsed)
    {
        using var f = new Fixture();
        Assert.That(f.Send(f.Command("start"))["ok"].Value<bool>(), Is.True);
        f.Advance(0f, elapsed);
        string phase = f.Phase;
        Vector3 position = f.Actor.position;
        var result = f.SendTicket("setPhoneInteraction", new JObject {
            ["requestId"] = "composer-focus", ["interactionId"] = "composer-1",
            ["phase"] = "reading", ["sequence"] = 1,
            ["expiresAtMs"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 5000,
        });
        Assert.That(result["code"].Value<string>(), Is.EqualTo("presentation_busy"));
        Assert.That(f.Field<string>("hostBackgroundWorkSessionId"), Is.EqualTo(Session));
        Assert.That(f.Phase, Is.EqualTo(phase));
        Assert.That(f.Actor.position, Is.EqualTo(position));
        f.Advance(0f, 20f);
        Assert.That(f.Phase, Is.EqualTo("working"));
        Assert.That(f.Send(f.Command("end"))["ok"].Value<bool>(), Is.True,
            "Only the explicit host task end should release the desk.");
    }

    [Test]
    public void ARealLoadedAvatarCanWalkSitTypeAndReportTheDeskWithoutAProjectionOwner()
    {
        using var f = new Fixture();
        Vector3 homePosition = f.Actor.position;
        Quaternion homeRotation = f.Actor.rotation;
        Assert.That(f.LoadResult["backgroundTaskWorkVersion"].Value<int>(), Is.EqualTo(2));
        Assert.That(f.Field<string>("avatarArbiterOwnerToken"), Is.Empty);
        Assert.That(f.Send(f.Command("start"))["ok"].Value<bool>(), Is.True);
        f.Advance(0f, 15f);
        Assert.That(f.Phase, Is.EqualTo("working"));
        object display = f.Field<object>("deskWorkDisplay");
        Assert.That(display, Is.Not.Null);
        Assert.That(display.GetType().GetProperty("IsLit").GetValue(display), Is.EqualTo(true));
        JObject state = f.States.Last();
        Assert.That(state["sessionId"].Value<string>(), Is.EqualTo(Session));
        Assert.That(state["loadRequestId"].Value<string>(), Is.EqualTo(f.LoadId));
        Assert.That(state["workSessionId"].Value<string>(), Is.EqualTo(Session));
        Assert.That(state["furnitureId"].Value<string>(), Is.EqualTo("desk"));
        Assert.That(f.Framing.GetType().GetProperty("HasDeskWorkAnchor").GetValue(f.Framing), Is.EqualTo(true));
        Transform left = f.Animator.GetBoneTransform(HumanBodyBones.LeftHand);
        Transform right = f.Animator.GetBoneTransform(HumanBodyBones.RightHand);
        Vector3 leftBefore = left.position, rightBefore = right.position;
        f.Advance(15f, 15.1f);
        Assert.That(Vector3.Distance(left.position, leftBefore), Is.GreaterThan(.001f));
        Assert.That(Vector3.Distance(right.position, rightBefore), Is.GreaterThan(.001f));
        Assert.That(f.Send(f.Command("end"))["ok"].Value<bool>(), Is.True);
        Assert.That(display.GetType().GetProperty("IsLit").GetValue(display), Is.EqualTo(false),
            "The laptop turns off as soon as typing ends, before the actor walks home.");
        Assert.That(f.States.Last()["phase"].Value<string>(), Is.EqualTo("rising"));
        Assert.That(f.States.Last()["sessionId"].Value<string>(), Is.EqualTo(Session));
        f.Advance(0f, 20f);
        Assert.That(f.Phase, Is.EqualTo("standing"));
        Assert.That(Vector3.Distance(f.Actor.position, homePosition), Is.LessThan(.01f));
        Assert.That(Quaternion.Angle(f.Actor.rotation, homeRotation), Is.LessThan(.5f));
        foreach (JObject observation in f.States)
        {
            Assert.That(observation.Properties().Select(p => p.Name), Is.EquivalentTo(new[] {
                "method", "requestId", "sessionId", "loadRequestId", "phase", "furnitureId", "sceneId", "sequence", "workSessionId"
            }));
            string work = observation["workSessionId"]?.Value<string>();
            if (!string.IsNullOrEmpty(work))
            {
                Assert.That(work, Is.EqualTo(Session));
                CollectionAssert.Contains(new[] { "approaching", "aligning", "working" }, observation["phase"].Value<string>());
            }
        }
    }

    [Test]
    public void EndBeforeStartPermanentlyRetiresThatSessionEvenWithANewerSequence()
    {
        using var f = new Fixture();
        Assert.That(f.Send(f.Command("end"))["ok"].Value<bool>(), Is.True);
        JObject result = f.Send(f.Command("start"));
        Assert.That(result["code"].Value<string>(), Is.EqualTo("session_ended"));
        Assert.That(f.Phase, Is.EqualTo("standing"));
    }

    [Test]
    public void AUserFurnitureReplacementCannotBeMovedByTheRetiredTasksStop()
    {
        using var f = new Fixture();
        Assert.That(f.Send(f.Command("start"))["ok"].Value<bool>(), Is.True);
        f.Advance(0f, 15f);
        Assert.That(f.Call("BeginFurniture", "sit_sofa"), Is.EqualTo(true));
        f.Advance(0f, 20f);
        Assert.That(f.Phase, Is.EqualTo("seated"));
        Vector3 position = f.Actor.position;
        f.Send(f.Command("end"));
        Assert.That(f.Phase, Is.EqualTo("seated"));
        Assert.That(f.Actor.position, Is.EqualTo(position));
    }

    [TestCase("pause")]
    [TestCase("hidden")]
    [TestCase("scene")]
    public void AStartUnityHasNeverSeenCannotCrossAPresentationRetirement(string boundary)
    {
        using var f = new Fixture();
        JObject delayed = f.Command("start");
        delayed["issuedAtEpochMs"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - 10;
        delayed["deadlineEpochMs"] = delayed["issuedAtEpochMs"].Value<long>() + 10000;
        if (boundary == "pause") { f.Call("OnApplicationPause", true); f.Call("OnApplicationPause", false); }
        else if (boundary == "hidden") { f.Visible(false); f.Visible(true); }
        else f.Call("CancelLoginDoorway", "scene_takeover");
        Assert.That(f.Send(delayed)["code"].Value<string>(), Is.EqualTo("session_ended"));
        Assert.That(f.Phase, Is.EqualTo("standing"));
        Assert.That(f.Send(f.Command("start", OtherSession))["ok"].Value<bool>(), Is.True,
            "A current foreground task must still work without reloading the same model after pause.");
    }

    [Test]
    public void SceneRetirementReturnsOnlyItsCurrentHostWorkToItsSavedHomePose()
    {
        using var f = new Fixture();
        Vector3 home = f.Actor.position;
        Quaternion facing = f.Actor.rotation;
        Assert.That(f.Send(f.Command("start"))["ok"].Value<bool>(), Is.True);
        f.Advance(0f, 15f);
        Assert.That(Vector3.Distance(f.Actor.position, home), Is.GreaterThan(.1f));
        f.Call("CancelLoginDoorway", "scene_takeover");
        Assert.That(f.Field<string>("hostBackgroundWorkSessionId"), Is.Null);
        Assert.That(f.Phase, Is.EqualTo("standing"));
        Assert.That(Vector3.Distance(f.Actor.position, home), Is.LessThan(.001f));
        Assert.That(Quaternion.Angle(f.Actor.rotation, facing), Is.LessThan(.01f));
        Assert.That(f.Send(f.Command("start"))["code"].Value<string>(), Is.EqualTo("session_ended"));
    }

    [TestCase("pause", 0f)]
    [TestCase("pause", 15f)]
    [TestCase("hidden", 0f)]
    [TestCase("hidden", 15f)]
    public void TemporaryPresentationLossPreservesTheAdmittedTaskAndSeatedPose(string boundary, float elapsed)
    {
        using var f = new Fixture();
        Vector3 home = f.Actor.position;
        Quaternion facing = f.Actor.rotation;
        Assert.That(f.Send(f.Command("start"))["ok"].Value<bool>(), Is.True);
        f.Advance(0f, elapsed);
        string phase = f.Phase;
        Vector3 root = f.Actor.position;
        Transform hips = f.Animator.GetBoneTransform(HumanBodyBones.Hips);
        Vector3 pelvis = hips.position;
        if (boundary == "pause") f.Call("OnApplicationPause", true);
        else f.Visible(false);
        Assert.That(f.Field<string>("hostBackgroundWorkSessionId"), Is.EqualTo(Session));
        Assert.That(f.Phase, Is.EqualTo(phase));
        Assert.That(Vector3.Distance(f.Actor.position, root), Is.LessThan(.001f));
        Assert.That(Vector3.Distance(hips.position, pelvis), Is.LessThan(.001f),
            "A temporarily hidden task must not restore standing bones inside the chair.");
        object display = f.Field<object>("deskWorkDisplay");
        if (display != null) Assert.That(display.GetType().GetProperty("IsLit").GetValue(display), Is.EqualTo(false));
        if (boundary == "pause") f.Call("OnApplicationPause", false);
        else f.Visible(true);
        Assert.That(f.Send(f.Command("start"))["ok"].Value<bool>(), Is.True);
        f.Advance(0f, 20f);
        Assert.That(f.Phase, Is.EqualTo("working"));
        display = f.Field<object>("deskWorkDisplay");
        Assert.That(display.GetType().GetProperty("IsLit").GetValue(display), Is.EqualTo(true));
        Assert.That(f.Send(f.Command("end"))["ok"].Value<bool>(), Is.True);
        f.Advance(0f, 20f);
        Assert.That(f.Phase, Is.EqualTo("standing"));
        Assert.That(Vector3.Distance(f.Actor.position, home), Is.LessThan(.001f));
        Assert.That(Quaternion.Angle(f.Actor.rotation, facing), Is.LessThan(.01f));
    }

    [TestCase("pause")]
    [TestCase("hidden")]
    public void CompletionWhileHiddenReturnsHomeAndCannotResumeTheCompletedTask(string boundary)
    {
        using var f = new Fixture();
        Vector3 home = f.Actor.position;
        Quaternion facing = f.Actor.rotation;
        Assert.That(f.Send(f.Command("start"))["ok"].Value<bool>(), Is.True);
        f.Advance(0f, 15f);
        if (boundary == "pause") f.Call("OnApplicationPause", true);
        else f.Visible(false);
        Assert.That(f.Send(f.Command("end"))["ok"].Value<bool>(), Is.True);
        Assert.That(f.Phase, Is.EqualTo("rising"));
        if (boundary == "pause") f.Call("OnApplicationPause", false);
        else f.Visible(true);
        Assert.That(f.Send(f.Command("start"))["code"].Value<string>(), Is.EqualTo("session_ended"));
        f.Advance(0f, 20f);
        Assert.That(f.Phase, Is.EqualTo("standing"));
        Assert.That(f.Field<string>("hostBackgroundWorkSessionId"), Is.Null);
        Assert.That(Vector3.Distance(f.Actor.position, home), Is.LessThan(.001f));
        Assert.That(Quaternion.Angle(f.Actor.rotation, facing), Is.LessThan(.01f));
    }

    [TestCase("pause")]
    [TestCase("hidden")]
    public void HidingDuringTheReturnJourneyDoesNotLoseTheSavedHomeOrigin(string boundary)
    {
        using var f = new Fixture();
        Vector3 home = f.Actor.position;
        Quaternion facing = f.Actor.rotation;
        Assert.That(f.Send(f.Command("start"))["ok"].Value<bool>(), Is.True);
        f.Advance(0f, 15f);
        Assert.That(f.Send(f.Command("end"))["ok"].Value<bool>(), Is.True);
        f.Advance(0f, .4f);
        if (boundary == "pause") f.Call("OnApplicationPause", true);
        else f.Visible(false);
        Assert.That(f.Field<string>("hostBackgroundWorkSessionId"), Is.EqualTo(Session));
        Assert.That(f.Phase, Is.EqualTo("rising"));
        if (boundary == "pause") f.Call("OnApplicationPause", false);
        else f.Visible(true);
        f.Advance(.4f, 20f);
        Assert.That(f.Phase, Is.EqualTo("standing"));
        Assert.That(Vector3.Distance(f.Actor.position, home), Is.LessThan(.001f));
        Assert.That(Quaternion.Angle(f.Actor.rotation, facing), Is.LessThan(.01f));
    }

    [TestCase("pause")]
    [TestCase("hidden")]
    public void ADelayedDuplicateForTheAlreadyAdmittedTaskCanCrossTheTransientBarrier(string boundary)
    {
        using var f = new Fixture();
        Assert.That(f.Send(f.Command("start"))["ok"].Value<bool>(), Is.True);
        f.Advance(0f, 15f);
        JObject duplicate = f.Command("start");
        duplicate["issuedAtEpochMs"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - 10;
        duplicate["deadlineEpochMs"] = duplicate["issuedAtEpochMs"].Value<long>() + 10000;
        if (boundary == "pause") { f.Call("OnApplicationPause", true); f.Call("OnApplicationPause", false); }
        else { f.Visible(false); f.Visible(true); }
        Assert.That(f.Send(duplicate)["ok"].Value<bool>(), Is.True);
        Assert.That(f.Phase, Is.EqualTo("working"));
        Assert.That(f.Field<string>("hostBackgroundWorkSessionId"), Is.EqualTo(Session));
    }

    [Test]
    public void ModelReplacementAndDisableRejectTheOldLoadIdentity()
    {
        using var f = new Fixture();
        JObject old = f.Command("start");
        f.Reload("model-new");
        Assert.That(f.Send(old)["code"].Value<string>(), Is.EqualTo("model_stale"));
        Assert.That(f.Send(f.Command("start", OtherSession))["ok"].Value<bool>(), Is.True);
        f.Call("OnDisable");
        Assert.That(f.Field<string>("hostBackgroundWorkLoadRequestId"), Is.Null);
        Assert.That(f.Field<string>("hostBackgroundWorkSessionId"), Is.Null);
    }

    [Test]
    public void ABoundProjectionOwnerCannotBeBypassedByTheHostWorkLane()
    {
        using var f = new Fixture();
        f.Set("avatarArbiterOwnerToken", new string('c', 64));
        Assert.That(f.Send(f.Command("start"))["code"].Value<string>(), Is.EqualTo("authority_owned"));
        Assert.That(f.Phase, Is.EqualTo("standing"));
    }

    [Test]
    public void ExplicitUserPosturesAreTerminalWhileHiddenPresentationIsTransient()
    {
        using var f = new Fixture();
        Assert.That(f.Call("BeginFurniture", "sit_sofa"), Is.EqualTo(true));
        Assert.That(f.Send(f.Command("start"))["code"].Value<string>(), Is.EqualTo("user_pose_owned"));
        f.FurnitureCall("Reset", false);
        f.Visible(false);
        Assert.That(f.Send(f.Command("start", OtherSession))["code"].Value<string>(), Is.EqualTo("presentation_busy"));
    }

    [TestCase("extra")]
    [TestCase("float-sequence")]
    [TestCase("expired")]
    [TestCase("future-issued")]
    public void ClosedHostRequestsRejectExtraOperationsAndInvalidClocks(string kind)
    {
        using var f = new Fixture();
        JObject command = f.Command("start");
        if (kind == "extra") command["gesture"] = "jump";
        else if (kind == "float-sequence") command["sequence"] = 1.5;
        else if (kind == "expired")
        {
            command["issuedAtEpochMs"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - 10001;
            command["deadlineEpochMs"] = command["issuedAtEpochMs"].Value<long>() + 10000;
        }
        else
        {
            command["issuedAtEpochMs"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 2000;
            command["deadlineEpochMs"] = command["issuedAtEpochMs"].Value<long>() + 10000;
        }
        JObject result = f.Send(command);
        Assert.That(result["ok"].Value<bool>(), Is.False);
        Assert.That(result["code"].Value<string>(), Is.EqualTo(kind == "expired" ? "deadline_expired" : "invalid_command"));
        Assert.That(result.Properties().Select(p => p.Name), Is.EquivalentTo(new[] {
            "method", "requestId", "sessionId", "phase", "loadRequestId", "sequence", "ok", "code"
        }));
        Assert.That(f.Phase, Is.EqualTo("standing"));
    }

    [Test]
    public void ReplayingASequenceCannotRestartTheRealWalk()
    {
        using var f = new Fixture();
        JObject command = f.Command("start");
        Assert.That(f.Send(command)["ok"].Value<bool>(), Is.True);
        f.Advance(0f, 1f);
        Vector3 position = f.Actor.position;
        Assert.That(f.Send(command)["code"].Value<string>(), Is.EqualTo("stale_sequence"));
        Assert.That(f.Actor.position, Is.EqualTo(position));
    }

    [Test]
    public void AnExpiredExactStopStillReleasesTypingWithoutStartingAnyMovement()
    {
        using var f = new Fixture();
        Assert.That(f.Send(f.Command("start"))["ok"].Value<bool>(), Is.True);
        f.Advance(0f, 15f);
        JObject stop = f.Command("end");
        stop["issuedAtEpochMs"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - 10001;
        stop["deadlineEpochMs"] = stop["issuedAtEpochMs"].Value<long>() + 10000;
        Assert.That(f.Send(stop)["code"].Value<string>(), Is.EqualTo("deadline_expired"));
        Assert.That(f.Phase, Is.EqualTo("rising"));
        f.Advance(0f, 20f);
        Assert.That(f.Phase, Is.EqualTo("standing"));
        Assert.That(f.Field<string>("hostBackgroundWorkSessionId"), Is.Null);
    }

    [Test]
    public void ADelayedExpiredStopCannotTouchTheUsersReplacementPose()
    {
        using var f = new Fixture();
        Assert.That(f.Send(f.Command("start"))["ok"].Value<bool>(), Is.True);
        f.Advance(0f, 15f);
        Assert.That(f.Call("BeginFurniture", "sit_sofa"), Is.EqualTo(true));
        f.Advance(0f, 20f);
        Vector3 position = f.Actor.position;
        JObject stop = f.Command("end");
        stop["issuedAtEpochMs"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - 10001;
        stop["deadlineEpochMs"] = stop["issuedAtEpochMs"].Value<long>() + 10000;
        f.Send(stop);
        Assert.That(f.Phase, Is.EqualTo("seated"));
        Assert.That(f.Actor.position, Is.EqualTo(position));
    }

    [Test]
    public void TheDesktopBridgeAllowsOnlyTheDeclaredClosedWorkMethod()
    {
        Type bridge = Type.GetType("Maaso.Avatar.DesktopUnitySidecarBridge, Assembly-CSharp", true);
        MethodInfo supports = bridge.GetMethod("SupportsAvatarMethod", BindingFlags.Public | BindingFlags.Static);
        Assert.That(supports.Invoke(null, new object[] { "setBackgroundTaskWork" }), Is.EqualTo(true));
        Assert.That(supports.Invoke(null, new object[] { "setBackgroundTaskWorkScript" }), Is.EqualTo(false));
    }

    [Test]
    public void AValidatedTicketTakesOverHostWorkAndOnlyAStrictNeutralResetReleasesItAgain()
    {
        using var f = new Fixture();
        Assert.That(f.Send(f.Command("start"))["ok"].Value<bool>(), Is.True);
        JObject mouth = Ticket(owner: 'A', account: 7, renderer: 1, ticket: 1);
        Assert.That(f.SendTicket("avatarArbiterCommand", mouth)["ok"].Value<bool>(), Is.True);
        Assert.That(f.Field<string>("hostBackgroundWorkSessionId"), Is.Null);
        Assert.That(f.Phase, Is.EqualTo("standing"));
        Assert.That(f.Field<bool>("avatarArbiterLegacyReleased"), Is.False);
        Assert.That(f.Send(f.Command("start", OtherSession))["code"].Value<string>(), Is.EqualTo("authority_owned"));
        Assert.That(f.SendTicket("avatarArbiterReset", Reset('B', 7, 1, 8, 2))["ok"].Value<bool>(), Is.True);
        Assert.That(f.Field<string>("avatarArbiterOwnerToken"), Is.EqualTo(new string('B', 43)),
            "Releasing the host lane must not erase the ticket owner's anti-replay identity.");
        Assert.That(f.Field<bool>("avatarArbiterLegacyReleased"), Is.True);
        Assert.That(f.Send(f.Command("start", OtherSession))["ok"].Value<bool>(), Is.True);
        Assert.That(f.Field<string>("hostBackgroundWorkSessionId"), Is.EqualTo(OtherSession));
    }

    [Test]
    public void InvalidAndRetiredTicketsCannotInterruptNormalWorkAfterADormantReset()
    {
        using var f = new Fixture();
        Assert.That(f.SendTicket("avatarArbiterCommand", Ticket('A', 7, 1, 1))["ok"].Value<bool>(), Is.True);
        Assert.That(f.SendTicket("avatarArbiterReset", Reset('B', 7, 1, 8, 2))["ok"].Value<bool>(), Is.True);
        Assert.That(f.Send(f.Command("start"))["ok"].Value<bool>(), Is.True);
        long barrier = f.Field<long>("hostBackgroundWorkNotBeforeUtcMs");
        JObject invalid = Ticket('B', 8, 2, 1);
        invalid["payloadSha256"] = new string('f', 64);
        Assert.That(f.SendTicket("avatarArbiterCommand", invalid)["ok"].Value<bool>(), Is.False);
        Assert.That(f.SendTicket("avatarArbiterCommand", Ticket('A', 7, 1, 2))["ok"].Value<bool>(), Is.False);
        Assert.That(f.Field<bool>("avatarArbiterLegacyReleased"), Is.True);
        Assert.That(f.Field<string>("hostBackgroundWorkSessionId"), Is.EqualTo(Session));
        Assert.That(f.Field<long>("hostBackgroundWorkNotBeforeUtcMs"), Is.EqualTo(barrier));
    }

    [Test]
    public void AnOldResetCannotReopenTheHostLaneAfterANewerTicket()
    {
        using var f = new Fixture();
        Assert.That(f.SendTicket("avatarArbiterCommand", Ticket('A', 7, 1, 1))["ok"].Value<bool>(), Is.True);
        JObject reset = Reset('B', 7, 1, 8, 2);
        Assert.That(f.SendTicket("avatarArbiterReset", reset)["ok"].Value<bool>(), Is.True);
        Assert.That(f.SendTicket("avatarArbiterCommand", Ticket('B', 8, 2, 1))["ok"].Value<bool>(), Is.True);
        Assert.That(f.SendTicket("avatarArbiterReset", reset)["code"].Value<string>(), Is.EqualTo("reset_rejected"));
        Assert.That(f.SendTicket("avatarArbiterReset", Reset('C', 7, 1, 9, 3))["code"].Value<string>(), Is.EqualTo("reset_rejected"));
        Assert.That(f.Field<bool>("avatarArbiterLegacyReleased"), Is.False);
        Assert.That(f.Field<long>("avatarArbiterRendererGenerationHighWater"), Is.EqualTo(2));
        Assert.That(f.Send(f.Command("start"))["code"].Value<string>(), Is.EqualTo("authority_owned"));
    }

    [Test]
    public void TheOldHostsEndCannotMoveANewTaskAfterTicketOwnershipHasReturnedDormant()
    {
        using var f = new Fixture();
        Assert.That(f.Send(f.Command("start"))["ok"].Value<bool>(), Is.True);
        Assert.That(f.SendTicket("avatarArbiterCommand", Ticket('A', 7, 1, 1))["ok"].Value<bool>(), Is.True);
        Assert.That(f.SendTicket("avatarArbiterReset", Reset('B', 7, 1, 8, 2))["ok"].Value<bool>(), Is.True);
        Assert.That(f.Send(f.Command("start", OtherSession))["ok"].Value<bool>(), Is.True);
        Vector3 position = f.Actor.position;
        Assert.That(f.Send(f.Command("end"))["code"].Value<string>(), Is.EqualTo("session_mismatch"));
        Assert.That(f.Field<string>("hostBackgroundWorkSessionId"), Is.EqualTo(OtherSession));
        Assert.That(f.Actor.position, Is.EqualTo(position));
    }

    private static JObject Ticket(char owner, long account, long renderer, long ticket)
    {
        const string payload = "{\"channel\":\"mouth\",\"value\":0.62}";
        return new JObject {
            ["protocolVersion"] = 1, ["requestId"] = "proof-mouth-" + owner + ticket,
            ["ticket"] = ticket, ["rendererId"] = "test-renderer", ["ownerToken"] = new string(owner, 43),
            ["commitToken"] = new string('D', 43), ["accountGeneration"] = account,
            ["rendererGeneration"] = renderer, ["channel"] = "mouth", ["fingerprint"] = "0123456789abcdef",
            ["payloadJson"] = payload, ["payloadSha256"] = Hash(payload),
            ["deadlineEpochMs"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 4000, ["clearsChannel"] = false,
        };
    }

    private static JObject Reset(char owner, long retiredAccount, long retiredRenderer, long targetAccount, long targetRenderer)
    {
        const string payload = "{\"reset\":true}";
        return new JObject {
            ["protocolVersion"] = 1, ["requestId"] = "proof-reset-" + owner + targetRenderer,
            ["requirementId"] = targetRenderer, ["rendererId"] = "test-renderer", ["targetOwnerToken"] = new string(owner, 43),
            ["commitToken"] = new string('D', 43), ["retiredAccountGeneration"] = retiredAccount,
            ["retiredRendererGeneration"] = retiredRenderer, ["targetAccountGeneration"] = targetAccount,
            ["targetRendererGeneration"] = targetRenderer, ["payloadJson"] = payload, ["payloadSha256"] = Hash(payload),
            ["deadlineEpochMs"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 4000,
        };
    }

    private static string Hash(string value)
    {
        using var hash = SHA256.Create();
        return string.Concat(hash.ComputeHash(Encoding.UTF8.GetBytes(value)).Select(item => item.ToString("x2")));
    }

    private sealed class Fixture : IDisposable
    {
        private const string Prefix = "[UnityAvatar] command result ";
        public readonly Component Receiver, Framing;
        public readonly Transform Actor;
        public readonly Animator Animator;
        private readonly GameObject room, host, camera;
        private readonly Dictionary<Renderer, Material[]> borrowedMaterials;
        private readonly List<JObject> observations = new();
        private long sequence;
        public string LoadId { get; private set; }
        public JObject LoadResult { get; private set; }
        private object Furniture => Field<object>("furniturePose");
        public string Phase => (string)Furniture.GetType().GetProperty("Phase").GetValue(Furniture);
        public IEnumerable<JObject> States => observations.Where(message => message["method"]?.Value<string>() == "backgroundTaskWorkState");

        public Fixture()
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            Actor = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm")).transform;
            Actor.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            borrowedMaterials = Actor.GetComponentsInChildren<Renderer>(true)
                .Where(renderer => renderer is SkinnedMeshRenderer || renderer is MeshRenderer)
                .ToDictionary(renderer => renderer, renderer => renderer.sharedMaterials);
            Animator = Actor.GetComponentInChildren<Animator>(true);
            Animator.runtimeAnimatorController = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>("Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller");
            Animator.Rebind(); Animator.Update(0f); Animator.enabled = false;
            room = Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));
            host = new GameObject("Closed host work receiver");
            Receiver = host.AddComponent(Type.GetType("Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp", true));
            Set("avatarRoot", Actor); Set("bundledAvatarRoot", Actor); Set("animator", Animator);
            camera = new GameObject("Closed host work camera");
            camera.tag = "MainCamera"; camera.AddComponent<Camera>();
            Framing = camera.AddComponent(Type.GetType("Maaso.Avatar.FrontFullBodyCamera, Assembly-CSharp", true));
            Framing.GetType().GetProperty("TargetRoot").SetValue(Framing, Actor);
            Application.logMessageReceived += Capture;
            // Joy's first real load initializes UniVRM's expression runtime.
            // Match only its reviewed EditMode material-instancing diagnostic;
            // subsequent reloads reuse the runtime and must emit no new errors.
            int materialSlots = borrowedMaterials.Values.Sum(materials => materials.Count(material => material != null));
            Assert.That(materialSlots, Is.EqualTo(17), "Reviewed Joy material inventory changed.");
            for (int slot = 0; slot < materialSlots; slot++)
                LogAssert.Expect(LogType.Error,
                    "Instantiating material due to calling renderer.material during edit mode. This will leak materials into the scene. You most likely want to use renderer.sharedMaterial instead.");
            Reload("model-current");
            Visible(true);
        }

        private void Capture(string message, string stack, LogType type)
        {
            if (message.StartsWith(Prefix, StringComparison.Ordinal)) observations.Add(JObject.Parse(message.Substring(Prefix.Length)));
        }

        public T Field<T>(string name) => (T)Receiver.GetType().GetField(name, BindingFlags.NonPublic | BindingFlags.Instance).GetValue(Receiver);
        public void Set(string name, object value) => Receiver.GetType().GetField(name, BindingFlags.NonPublic | BindingFlags.Instance).SetValue(Receiver, value);
        public object Call(string name, params object[] args) => Receiver.GetType().GetMethods(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
            .Single(method => method.Name == name && method.GetParameters().Length == args.Length).Invoke(Receiver, args);
        public object FurnitureCall(string name, params object[] args) => Furniture.GetType().GetMethod(name).Invoke(Furniture, args);

        private void SendEnvelope(string method, JObject data) => Call("OnFlutterCommand", new JObject { ["method"] = method, ["json"] = data.ToString(Newtonsoft.Json.Formatting.None) }.ToString(Newtonsoft.Json.Formatting.None));
        public void Visible(bool visible) => SendEnvelope("setLocalAvatarVisible", new JObject { ["visible"] = visible });
        public void Reload(string id)
        {
            LoadId = id;
            SendEnvelope("loadAvatar", new JObject { ["requestId"] = id, ["modelUrl"] = "unity://masso/avatar_agent" });
            LoadResult = observations.Last(message => message["method"]?.Value<string>() == "loadAvatar");
            Assert.That(LoadResult["ok"].Value<bool>(), Is.True, "The fixture must use an actual matched successful native load.");
        }

        public JObject Command(string phase, string session = Session)
        {
            long issued = Math.Max(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 10, Field<long>("hostBackgroundWorkNotBeforeUtcMs") + 1);
            return new JObject {
                ["requestId"] = "host-work-" + ++sequence, ["sessionId"] = session, ["phase"] = phase,
                ["loadRequestId"] = LoadId, ["sequence"] = sequence,
                ["issuedAtEpochMs"] = issued, ["deadlineEpochMs"] = issued + 10000,
            };
        }

        public JObject Send(JObject command)
        {
            SendEnvelope("setBackgroundTaskWork", command);
            return observations.Last(message => message["method"]?.Value<string>() == "setBackgroundTaskWork");
        }

        public JObject SendTicket(string method, JObject command)
        {
            SendEnvelope(method, command);
            return observations.Last(message => message["method"]?.Value<string>() == method);
        }

        public void Advance(float from, float to)
        {
            float started = (float)Furniture.GetType().GetField("started", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(Furniture);
            for (float time = from; time <= to + .001f; time += 1f / 60f)
                FurnitureCall("Advance", started + time, 1f / 60f);
        }

        public void Dispose()
        {
            Application.logMessageReceived -= Capture;
            if (Receiver != null) Object.DestroyImmediate(host);
            var borrowed = new HashSet<Material>(borrowedMaterials.Values.SelectMany(materials => materials));
            Material[] clones = borrowedMaterials.Keys.Where(renderer => renderer != null)
                .SelectMany(renderer => renderer.sharedMaterials)
                .Where(material => material != null && !borrowed.Contains(material) && !AssetDatabase.Contains(material))
                .Distinct().ToArray();
            foreach (var pair in borrowedMaterials)
                if (pair.Key != null) pair.Key.sharedMaterials = pair.Value;
            foreach (Material clone in clones) Object.DestroyImmediate(clone);
            var vrm = Actor != null ? Actor.GetComponent<Vrm10Instance>() : null;
            if (vrm != null && vrm.Runtime.ControlRig != null)
            {
                Object.DestroyImmediate(vrm.Runtime.ControlRig.ControlRigAnimator.avatar);
                Transform controls = vrm.transform.Find("Runtime Control Rig");
                if (controls != null) Object.DestroyImmediate(controls.gameObject);
            }
            if (Actor != null) Object.DestroyImmediate(Actor.gameObject);
            if (room != null) Object.DestroyImmediate(room);
            if (camera != null) Object.DestroyImmediate(camera);
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        }
    }
}

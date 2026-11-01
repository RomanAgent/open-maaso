using System.Collections.Generic;
using System;
using System.Reflection;
using System.Linq.Expressions;
using System.Linq;
using System.IO;
using UnityEditor.SceneManagement;
using UniVRM10;
using UnityEngine.TestTools;
using System.Text.RegularExpressions;
using Object = UnityEngine.Object;
using NUnit.Framework;
using UnityEngine;

public sealed class AvatarPresenceTransitionTests
{
    [Test]
    public void HomeArrivalStopsWalkingAtTheCentreOnceBeforeTurningToTheCamera()
    {
        using var f = new Fixture();
        f.Execute("prepare");
        f.Execute("enter", edge: "right");
        int preparationStops = f.Stops;
        f.Controller.Advance(.84f, 1840);
        Assert.That(f.Stops, Is.EqualTo(preparationStops));
        f.Controller.Advance(.85f, 1850);
        Assert.That(f.Avatar.position, Is.EqualTo(Vector3.zero));
        Assert.That(f.Stops, Is.EqualTo(preparationStops + 1),
            "A centred actor must blend to idle while it turns, instead of walking on the spot.");
        f.Controller.Advance(.96f, 1960);
        f.Controller.Advance(1f, 2000);
        f.Controller.Advance(1.1f, 2100);
        Assert.That(f.Stops, Is.EqualTo(preparationStops + 1),
            "Completing and restoring the same entrance must not ask for idle again.");
        Assert.That(f.Controller.OwnsPresentation, Is.False);
        Assert.That(f.Results.Last().ok, Is.True);
    }

    [Test]
    public void HomeArrivalTurnHasASettledStartAndFinishRatherThanAnAbruptAngularStop()
    {
        using var f = new Fixture();
        f.Execute("prepare");
        f.Execute("enter", edge: "right");
        f.Controller.Advance(.85f, 1850);
        Quaternion start = f.Avatar.rotation;
        f.Controller.Advance(.865f, 1865);
        float firstStep = Quaternion.Angle(start, f.Avatar.rotation);
        f.Controller.Advance(.91f, 1910);
        Quaternion middle = f.Avatar.rotation;
        f.Controller.Advance(.925f, 1925);
        float middleStep = Quaternion.Angle(middle, f.Avatar.rotation);
        f.Controller.Advance(.985f, 1985);
        Quaternion penultimate = f.Avatar.rotation;
        f.Controller.Advance(1f, 2000);
        float lastStep = Quaternion.Angle(penultimate, f.Avatar.rotation);
        Assert.That(firstStep, Is.LessThan(middleStep * .6f), "Turning must begin with a small angular step.");
        Assert.That(lastStep, Is.LessThan(middleStep * .6f), "Facing the camera must settle instead of snapping to a halt.");
        Assert.That(Quaternion.Angle(f.Avatar.rotation, Quaternion.identity), Is.LessThan(.01f));
    }

    [Test]
    public void NativeDesktopArrivalKeepsWalkingUntilItsWindowRouteFinishesAndStopsOnlyOnce()
    {
        using var f = new Fixture();
        f.Execute("prepare", stationary: true);
        f.Execute("enter", stationary: true);
        int preparationStops = f.Stops;
        f.Controller.Advance(.85f, 1850);
        Assert.That(f.Stops, Is.EqualTo(preparationStops),
            "The native desktop window is still moving during this stationary Unity walk.");
        f.Controller.Advance(1f, 2000);
        Assert.That(f.Stops, Is.EqualTo(preparationStops + 1));
    }

    [TestCase("hero_full_body")]
    [TestCase("full_body")]
    [TestCase(" FULL BODY ")]
    public void HomeFramingAndViewportReplaysDoNotInterruptStartup(string mode)
    {
        using var f = new ReceiverFixture();
        f.Start();
        Vector3 entering = f.Actor.Avatar.position;
        f.Send("setFraming", "{\"mode\":\"" + mode + "\"}");
        f.Send("setViewportSafeArea", "{\"topSafeViewport\":0.1,\"bottomSafeViewport\":0.2}");
        Assert.That(f.Actor.Controller.OwnsPresentation, Is.True);
        Assert.That(f.Actor.Avatar.position, Is.EqualTo(entering));
        f.Actor.Controller.Advance(1.1f, 2100);
        Assert.That(f.Actor.Results.Last().ok, Is.True);
        Assert.That(f.Actor.Avatar.position, Is.EqualTo(f.Home));
    }

    [Test]
    public void SelfieCloseupRetiresStartupBeforeChangingCameraAndLateCleanupCannotUndoIt()
    {
        using var f = new ReceiverFixture();
        f.Start();
        f.Send("setFraming", "{\"mode\":\"head\"}");
        Assert.That(f.Actor.Controller.OwnsPresentation, Is.False);
        Assert.That(f.Actor.Results.Last().code, Is.EqualTo("scene_takeover"));
        Assert.That(f.Actor.Avatar.position, Is.EqualTo(f.Home));
        Assert.That(f.Actor.FramingMode, Is.EqualTo("head"));
        Vector3 camera = f.Actor.Camera.transform.position;
        f.Actor.Execute("restore");
        f.Actor.Execute("holdHidden");
        f.Actor.Controller.Advance(2f, 3000);
        Assert.That(f.Actor.Results.Last().ok, Is.False);
        Assert.That(f.Actor.FramingMode, Is.EqualTo("head"));
        Assert.That(f.Actor.Camera.transform.position, Is.EqualTo(camera));
        Assert.That(f.Actor.Mesh.forceRenderingOff, Is.False);
    }

    [Test]
    public void SceneTakeoverNeverReleasesADeviceHandoff()
    {
        using var f = new ReceiverFixture();
        f.Start(opportunistic: false);
        Vector3 entering = f.Actor.Avatar.position;
        f.Send("setFraming", "{\"mode\":\"head\"}");
        Assert.That(f.Actor.Controller.OwnsPresentation, Is.True);
        Assert.That(f.Actor.FramingMode, Is.EqualTo("hero_full_body"));
        var worldParent = new GameObject("World parent");
        try
        {
            Assert.That(f.Call("TryLeaseActiveAvatarForWorld", worldParent.transform), Is.False);
            f.Call("ReleaseStartupPresenceForScene", new object[] { null });
            Assert.That(f.Actor.Controller.OwnsPresentation, Is.True);
            Assert.That(f.Actor.Avatar.position, Is.EqualTo(entering));
        }
        finally { Object.DestroyImmediate(worldParent); }
    }

    [TestCase("prepare")]
    [TestCase("holdHidden")]
    [TestCase("exit")]
    public void HomeEntranceCannotInterruptAnActiveHandoff(string phase)
    {
        using var f = new Fixture();
        f.Execute("prepare", transaction: "handoff");
        f.Execute("enter", transaction: "handoff", edge: "right");
        f.Controller.Advance(0.35f, 1350);
        Vector3 position = f.Avatar.position;
        var opportunistic = f.Command(phase, transaction: "home-startup");
        opportunistic.doNotInterrupt = true;
        f.Execute(opportunistic);
        Assert.That(f.Results.Last().ok, Is.False);
        Assert.That(f.Results.Last().code, Is.EqualTo(phase == "holdHidden" ? "transition_mismatch" : "transition_busy"));
        Assert.That(f.Avatar.position, Is.EqualTo(position));
        Assert.That(f.Mesh.forceRenderingOff, Is.False);
        f.Controller.Advance(1.1f, 2100);
        Assert.That(f.Results.Last().transitionId, Is.EqualTo("handoff"));
        Assert.That(f.Results.Last().phase, Is.EqualTo("enter"));
        Assert.That(f.Results.Last().ok, Is.True);
    }

    [Test]
    public void ConfirmedRemoteLocationCanRetireACompletedHomePreview()
    {
        using var f = new Fixture();
        f.Execute("prepare", transaction: "home-entry");
        f.Execute("enter", transaction: "home-entry", edge: "right");
        f.Controller.Advance(1.1f, 2100);
        Assert.That(f.Controller.OwnsPresentation, Is.False);
        var departure = f.Command("exit", transaction: "home-departure", edge: "right");
        departure.doNotInterrupt = true;
        f.Execute(departure);
        Assert.That(f.Controller.OwnsPresentation, Is.True);
        Assert.That(f.Results.Last().phase, Is.EqualTo("enter"));
        Assert.That(f.Mesh.forceRenderingOff, Is.False);
        f.Controller.Advance(1.1f, 2100);
        Assert.That(f.Results.Last().phase, Is.EqualTo("exit"));
        Assert.That(f.Results.Last().ok, Is.True);
        Assert.That(f.Controller.IsHidden, Is.True);
    }

    [Test]
    public void HandoffCanSupersedeHomeAndLateHomeRestoreCannotRevealIt()
    {
        using var f = new Fixture();
        var prepare = f.Command("prepare", transaction: "home-startup");
        prepare.doNotInterrupt = true;
        f.Execute(prepare);
        f.Execute("prepare", transaction: "handoff");
        var cancel = f.Command("restore", transaction: "home-startup");
        cancel.doNotInterrupt = true;
        f.Execute(cancel);
        Assert.That(f.Results.Last().ok, Is.False);
        Assert.That(f.Mesh.forceRenderingOff, Is.True);
        f.Execute("enter", transaction: "handoff", edge: "right");
        f.Controller.Advance(1.1f, 2100);
        Assert.That(f.Results.Last().ok, Is.True);
        Assert.That(f.Results.Last().transitionId, Is.EqualTo("handoff"));
    }

    [Test]
    public void LateHomeCancellationCannotHideACompletedHandoff()
    {
        using var f = new Fixture();
        f.Execute("prepare", transaction: "handoff");
        f.Execute("enter", transaction: "handoff", edge: "right");
        f.Controller.Advance(1.1f, 2100);
        Assert.That(f.Controller.OwnsPresentation, Is.False);
        var cancel = f.Command("holdHidden", transaction: "home-never-prepared");
        cancel.doNotInterrupt = true;
        f.Execute(cancel);
        Assert.That(f.Results.Last().ok, Is.False);
        Assert.That(f.Results.Last().code, Is.EqualTo("transition_mismatch"));
        Assert.That(f.Mesh.forceRenderingOff, Is.False);
        Assert.That(f.View.enabled, Is.True);
    }

    [Test]
    public void HomeEntryRevealsEveryBoundsCornerOutsideScreenThenStandsAtHome()
    {
        using var f = new Fixture();
        Vector3 home = f.Avatar.position;
        var prepare = f.Command("prepare", transaction: "home-startup");
        prepare.doNotInterrupt = true;
        f.Execute(prepare);
        Assert.That(f.Mesh.forceRenderingOff, Is.True);
        var enter = f.Command("enter", transaction: "home-startup", edge: "right");
        enter.doNotInterrupt = true;
        enter.durationMs = 1800;
        f.Execute(enter);
        Bounds bounds = f.Mesh.bounds;
        for (int i = 0; i < 8; i++)
        {
            Vector3 corner = bounds.center + Vector3.Scale(bounds.extents,
                new Vector3((i & 1) == 0 ? -1 : 1, (i & 2) == 0 ? -1 : 1, (i & 4) == 0 ? -1 : 1));
            Assert.That(f.Camera.WorldToViewportPoint(corner).x, Is.GreaterThanOrEqualTo(1.079f));
        }
        f.Controller.Advance(0.9f, 1900);
        Assert.That(f.Avatar.position.x, Is.GreaterThan(home.x));
        Assert.That(f.Results.Count, Is.EqualTo(1), "Entry receipt must wait for standing at home.");
        f.Controller.Advance(1.81f, 2810);
        Assert.That(f.Avatar.position, Is.EqualTo(home));
        Assert.That(f.Avatar.rotation, Is.EqualTo(Quaternion.identity));
        Assert.That(f.Controller.OwnsPresentation, Is.False);
        Assert.That(f.Results.Last().ok, Is.True);
    }

    [TestCase(0.46f, false, true)]
    [TestCase(0.46f, false, false)]
    [TestCase(1.78f, false, true)]
    [TestCase(1.78f, false, false)]
    [TestCase(0.46f, true, true)]
    [TestCase(1.78f, true, false)]
    public void EntireBoundsExitRequestedViewportEdge(float aspect, bool orthographic, bool left)
    {
        using var fixture = new Fixture();
        fixture.Camera.aspect = aspect;
        fixture.Camera.orthographic = orthographic;
        fixture.Camera.orthographicSize = 3f;
        Bounds bounds = new(new Vector3(0f, 1f, 0f), new Vector3(1.4f, 2f, 0.8f));
        Vector3 offset = (Vector3)TypeOf("AvatarPresenceTransitionController").GetMethod("CalculateExitOffset").Invoke(null, new object[] {
            fixture.Camera, bounds, fixture.Camera.transform.right * (left ? -1 : 1), left });
        for (int i = 0; i < 8; i++)
        {
            Vector3 corner = bounds.center + Vector3.Scale(bounds.extents,
                new Vector3((i & 1) == 0 ? -1 : 1, (i & 2) == 0 ? -1 : 1, (i & 4) == 0 ? -1 : 1));
            float x = fixture.Camera.WorldToViewportPoint(corner + offset).x;
            Assert.That(left ? x <= -0.079f : x >= 1.079f, Is.True);
        }
    }

    [Test]
    public void ExitTurnsLeftWithFixedCameraAndOnlyAcknowledgesAfterHidden()
    {
        using var f = new Fixture();
        Vector3 cameraPosition = f.Camera.transform.position;
        f.Execute("exit");
        Assert.That(f.Results, Is.Empty);
        f.Controller.Advance(0.2f, 1200);
        Assert.That(Vector3.Dot(f.Avatar.forward, -f.Camera.transform.right), Is.GreaterThan(0.99f));
        f.Controller.Advance(0.6f, 1600);
        Assert.That(f.Camera.transform.position, Is.EqualTo(cameraPosition));
        Assert.That(f.Results, Is.Empty);
        f.Controller.Advance(1.1f, 2100);
        Assert.That(f.Results.Count, Is.EqualTo(1));
        Assert.That(f.Results[0].ok, Is.True);
        Assert.That(f.Controller.IsHidden, Is.True);
        Assert.That(f.Mesh.forceRenderingOff, Is.True);
        Assert.That(f.Camera.WorldToViewportPoint(f.Mesh.bounds.max).x, Is.LessThan(0f));
        Assert.That(f.View.enabled, Is.False);
    }

    [Test]
    public void PreparedEntryRevealsFromRightAndRestoresPoseFramingAndVisibility()
    {
        using var f = new Fixture();
        f.SetFraming("head");
        Vector3 position = f.Avatar.localPosition;
        f.Execute("prepare");
        Assert.That(f.Mesh.forceRenderingOff, Is.True);
        f.Execute("enter", edge: "right");
        Assert.That(f.Mesh.forceRenderingOff, Is.False);
        Assert.That(f.Camera.WorldToViewportPoint(f.Avatar.position).x, Is.GreaterThan(1f));
        Assert.That(f.Results.Count, Is.EqualTo(1));
        f.Controller.Advance(1.1f, 2100);
        Assert.That(f.Results[1].ok, Is.True);
        Assert.That(f.Avatar.localPosition, Is.EqualTo(position));
        Assert.That(f.Avatar.localRotation, Is.EqualTo(Quaternion.identity));
        Assert.That(f.View.enabled, Is.True);
        Assert.That(f.FramingMode, Is.EqualTo("head"));
        Assert.That(f.Controller.OwnsPresentation, Is.False);
    }

    [Test]
    public void DesktopStationaryEntryWalksWithoutTranslatingAndRevealsAtStart()
    {
        using var f = new Fixture();
        f.Execute("prepare");
        f.Execute("enter", stationary: true);
        Assert.That(f.Mesh.forceRenderingOff, Is.False);
        f.Controller.Advance(0.5f, 1500);
        Assert.That(f.Avatar.position, Is.EqualTo(Vector3.zero));
        Assert.That(f.Walks, Is.EqualTo(1));
        Assert.That(f.Results.Count, Is.EqualTo(1));
        f.Controller.Advance(1.1f, 2100);
        Assert.That(f.Results[1].ok, Is.True);
    }

    [TestCase(5000)]
    [TestCase(12000)]
    [TestCase(30000)]
    public void DesktopDepartureTurnsPromptlyAndWalksUntilNativeRouteFinishes(int durationMs)
    {
        using var f = new Fixture();
        var command = f.Command("exit", stationary: true);
        command.durationMs = durationMs;
        command.expiresAtMs = 1000 + durationMs + 5000;
        f.Execute(command);
        Assert.That(f.Results, Is.Empty);
        f.Controller.Advance(0.2f, 1200);
        Assert.That(Vector3.Dot(f.Avatar.forward, -f.Camera.transform.right), Is.GreaterThan(0.99f));
        for (float time = 1f; time < durationMs / 1000f; time += 0.5f)
        {
            f.Controller.Advance(time, 1000 + (long)(time * 1000));
            Assert.That(f.Results, Is.Empty, "Source must not acknowledge before the native window leaves");
            Assert.That(f.Controller.IsHidden, Is.False);
            Assert.That(f.Avatar.position, Is.EqualTo(Vector3.zero));
        }
        Assert.That(f.Walks, Is.EqualTo(1), "Longer travel must not restart the walk clip");
        f.Controller.Advance(durationMs / 1000f + 0.01f, 1010 + durationMs);
        Assert.That(f.Results.Single().ok, Is.True);
        Assert.That(f.Mesh.forceRenderingOff, Is.True);
    }

    [TestCase("enter", true)]
    [TestCase("exit", false)]
    [TestCase("prepare", true)]
    public void ExtendedDurationIsOnlyAvailableForNativeDesktopDeparture(string phase, bool stationary)
    {
        using var f = new Fixture();
        var command = f.Command(phase, stationary: stationary);
        command.durationMs = 12000;
        command.expiresAtMs = 18000;
        f.Execute(command);
        Assert.That(f.Results.Single().code, Is.EqualTo("invalid_or_expired_request"));
        Assert.That(f.Walks, Is.Zero);
    }

    [Test]
    public void RestoreCancelsPendingExitAndRestoresOriginalState()
    {
        using var f = new Fixture();
        f.Execute("exit");
        f.Controller.Advance(0.5f, 1500);
        f.Execute("restore");
        Assert.That(f.Results.Count, Is.EqualTo(2));
        Assert.That(f.Results[0].ok, Is.False);
        Assert.That(f.Results[0].code, Is.EqualTo("cancelled"));
        Assert.That(f.Results[1].ok, Is.True);
        Assert.That(f.Mesh.forceRenderingOff, Is.False);
        Assert.That(f.Avatar.position, Is.EqualTo(Vector3.zero));
        Assert.That(f.View.enabled, Is.True);
        f.Controller.Advance(3f, 4000);
        Assert.That(f.Results.Count, Is.EqualTo(2));
    }

    [Test]
    public void DesktopRestoreCanRetryNativeRevealWithoutReplayingEntry()
    {
        using var f = new Fixture();
        f.Execute("prepare", stationary: true);
        f.Execute("enter", stationary: true);
        f.Controller.Advance(1.1f, 2100);
        for (int retry = 0; retry < 3; retry++)
        {
            f.Execute("holdHidden", stationary: true);
            Assert.That(f.Controller.IsHidden, Is.True);
            f.Execute("prepare", stationary: true);
            f.Execute("restore", stationary: true);
            Assert.That(f.Controller.OwnsPresentation, Is.False);
            Assert.That(f.Mesh.forceRenderingOff, Is.False);
            Assert.That(f.Avatar.position, Is.EqualTo(Vector3.zero));
            Assert.That(f.View.enabled, Is.True);
        }
        Assert.That(f.Results.TrueForAll(result => result.ok), Is.True);
        Assert.That(f.Walks, Is.EqualTo(1));
        // A released presentation still cannot start another walk directly.
        f.Execute("enter", stationary: true);
        Assert.That(f.Results[^1].code, Is.EqualTo("transition_completed"));
        Assert.That(f.Walks, Is.EqualTo(1));
        f.Execute("prepare", transaction: "new-owner", stationary: true);
        f.Execute("restore", stationary: true);
        Assert.That(f.Results[^1].ok, Is.False);
        Assert.That(f.Mesh.forceRenderingOff, Is.True);
    }

    [Test]
    public void StaleRestoreCannotRevealANewerPreparedTransaction()
    {
        using var f = new Fixture();
        f.Execute("prepare", transaction: "old");
        f.Execute("prepare", transaction: "new");
        f.Execute("restore", transaction: "old");
        Assert.That(f.Results[2].ok, Is.False);
        Assert.That(f.Mesh.forceRenderingOff, Is.True);
        Assert.That(f.Controller.OwnsPresentation, Is.True);
    }

    [Test]
    public void DepartedPhoneCanPrepareAgainAndReturnToOriginalCenter()
    {
        using var f = new Fixture();
        f.Execute("exit", transaction: "phone-to-desktop");
        f.Controller.Advance(1.1f, 2100);
        Assert.That(f.Avatar.position.sqrMagnitude, Is.GreaterThan(1f));
        Assert.That(f.Mesh.forceRenderingOff, Is.True);
        f.Execute("prepare", transaction: "desktop-to-phone");
        Assert.That(f.Avatar.position, Is.EqualTo(Vector3.zero));
        Assert.That(f.Mesh.forceRenderingOff, Is.True);
        f.Execute("prepare", transaction: "desktop-to-phone");
        f.Execute("holdHidden", transaction: "desktop-to-phone");
        f.Execute("enter", transaction: "desktop-to-phone", edge: "right");
        f.Controller.Advance(1.1f, 2100);
        Assert.That(f.Avatar.position, Is.EqualTo(Vector3.zero));
        Assert.That(f.Mesh.forceRenderingOff, Is.False);
        Assert.That(f.View.enabled, Is.True);
        Assert.That(f.Results.TrueForAll(result => result.ok), Is.True);
    }

    [Test]
    public void LostEntryReceiptCanBeFencedHiddenWithoutLettingOlderHandoffHideNewOwner()
    {
        using var f = new Fixture();
        f.Execute("prepare", transaction: "old");
        f.Execute("enter", transaction: "old");
        f.Controller.Advance(1.1f, 2100);
        Assert.That(f.Controller.OwnsPresentation, Is.False);
        f.Execute("holdHidden", transaction: "old");
        Assert.That(f.Controller.IsHidden, Is.True);
        f.Execute("restore", transaction: "old");
        Assert.That(f.Mesh.forceRenderingOff, Is.False);
        f.Execute("prepare", transaction: "new");
        f.Execute("enter", transaction: "new");
        f.Controller.Advance(1.1f, 2100);
        f.Execute("holdHidden", transaction: "old");
        Assert.That(f.Results[^1].ok, Is.False);
        Assert.That(f.Mesh.forceRenderingOff, Is.False);
    }

    [Test]
    public void DesktopSidecarAllowlistAcceptsPresenceAndRejectsUnknownMethods()
    {
        MethodInfo supports = TypeOf("DesktopUnitySidecarBridge").GetMethod("SupportsAvatarMethod");
        Assert.That(supports.Invoke(null, new object[] { "transitionPresence" }), Is.True);
        Assert.That(supports.Invoke(null, new object[] { "setRawBone" }), Is.False);
        Assert.That(supports.Invoke(null, new object[] { null }), Is.False);
    }

    [Test]
    public void MountModelResetRequiresFreshPrepareBeforeSameHandoffCanEnter()
    {
        using var f = new Fixture();
        f.Execute("prepare");
        f.Controller.CancelForReset("model_replaced");
        f.Execute("enter");
        Assert.That(f.Results[^1].ok, Is.False);
        f.Execute("prepare");
        Assert.That(f.Results[^1].ok, Is.True);
        f.Execute("enter");
        f.Controller.Advance(1.1f, 2100);
        Assert.That(f.Results[^1].ok, Is.True);
        Assert.That(f.Mesh.forceRenderingOff, Is.False);
    }

    [Test]
    public void HoldHiddenFencesQueuedEntryBySequence()
    {
        using var f = new Fixture();
        f.Execute("prepare");
        AvatarPresenceCommand late = f.Command("enter");
        f.Execute("holdHidden");
        f.Execute(late);
        Assert.That(f.Results[^1].code, Is.EqualTo("stale_request"));
        Assert.That(f.Mesh.forceRenderingOff, Is.True);
        Assert.That(f.Walks, Is.Zero);
    }

    [TestCase("model_replaced")]
    [TestCase("renderer_disabled")]
    public void RendererResetFailsPendingCompletionAndRestoresCamera(string reason)
    {
        using var f = new Fixture();
        f.Execute("exit");
        f.Controller.CancelForReset(reason);
        Assert.That(f.Results[0].ok, Is.False);
        Assert.That(f.Results[0].code, Is.EqualTo(reason));
        Assert.That(f.Controller.OwnsPresentation, Is.False);
        Assert.That(f.View.enabled, Is.True);
        Assert.That(f.Mesh.forceRenderingOff, Is.False);
    }

    [Test]
    public void MissingWalkingClipFailsRatherThanSlidingAvatar()
    {
        using var f = new Fixture();
        f.CanWalk = false;
        f.Execute("exit");
        Assert.That(f.Results[0].code, Is.EqualTo("walk_unavailable"));
        Assert.That(f.Controller.OwnsPresentation, Is.False);
        Assert.That(f.Avatar.position, Is.EqualTo(Vector3.zero));
    }

    [Test]
    public void ExpiredRequestDoesNotMutateAndDuplicateDoesNotRestartWalk()
    {
        using var f = new Fixture();
        AvatarPresenceCommand expired = f.Command("exit");
        expired.expiresAtMs = 999;
        f.Execute(expired);
        Assert.That(f.Results[0].ok, Is.False);
        Assert.That(f.Walks, Is.Zero);
        AvatarPresenceCommand valid = f.Command("exit");
        f.Execute(valid);
        f.Controller.Advance(0.6f, 1600);
        f.Execute(valid);
        f.Controller.Advance(1.1f, 2100);
        Assert.That(f.Walks, Is.EqualTo(1));
        Assert.That(f.Results.Count, Is.EqualTo(2));
        Assert.That(f.Results[1].ok, Is.True);
    }

    [Test]
    public void RealReceiverWalksDefaultAvatarOutOfRoomThenReturnsFromOtherEdge()
    {
        EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
        Component receiver = Object.FindAnyObjectByType(TypeOf("UnityAvatarCommandReceiver")) as Component;
        object Invoke(object target, string name, params object[] args) => target.GetType()
            .GetMethods(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
            .Single(method => method.Name == name && method.GetParameters().Length == args.Length).Invoke(target, args);
        Vrm10Instance boundVrm = Object.FindAnyObjectByType<Vrm10Instance>();
        Assert.That(boundVrm, Is.Not.Null);
        // Unity logs UniVRM's EditMode material access once per material slot.
        int materialAccessCount = boundVrm.GetComponentsInChildren<Renderer>()
            .Where(renderer => renderer is SkinnedMeshRenderer || renderer is MeshRenderer)
            .Sum(renderer => renderer.sharedMaterials.Length);
        for (int index = 0; index < materialAccessCount; index++)
            LogAssert.Expect(LogType.Error, new Regex("Instantiating material due to calling renderer\\.material"));
        Invoke(receiver, "Awake");
        Invoke(receiver, "ApplyExpression");
        Invoke(receiver, "OnFlutterCommand", "{\"method\":\"setLocalAvatarVisible\",\"json\":\"{\\\"visible\\\":true}\"}");
        Transform avatar = (Transform)receiver.GetType().GetProperty("ActiveAvatarRoot").GetValue(receiver);
        Animator animator = avatar.GetComponentInChildren<Animator>(true);
        Assert.That(animator, Is.Not.Null);
        animator.Rebind();
        Invoke(receiver, "TryStartDesignedIdle");
        animator.Update(1f / 60f);
        Vrm10Instance vrm = avatar.GetComponentInChildren<Vrm10Instance>(true);
        vrm.Runtime.Process();
        Camera camera = Camera.main;
        Behaviour view = camera.GetComponent(TypeOf("FrontFullBodyCamera")) as Behaviour;
        view.GetType().GetProperty("TargetRoot").SetValue(view, avatar);
        GameObject room = Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));
        try
        {
            Component map = room.GetComponent(Type.GetType("Maaso.World.PersistentWorldMapController, Assembly-CSharp", true));
            Invoke(map, "SetWorldActive", false);
            Invoke(map, "AlignHomeAvatar", avatar);
            camera.aspect = 393f / 852f;
            Invoke(view, "FrameNow");
            Vector3 homePosition = avatar.position;
            Vector3 cameraPosition = camera.transform.position;
            Quaternion cameraRotation = camera.transform.rotation;
            long now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            long seq = 0;
            void Send(string phase, string transaction, string edge)
            {
                AvatarPresenceCommand command = new() { requestId = "real-" + ++seq, transitionId = transaction,
                    phase = phase, edge = edge, durationMs = 1000, sequence = seq, expiresAtMs = now + 12000 };
                string json = JsonUtility.ToJson(command);
                Invoke(receiver, "OnFlutterCommand", "{\"method\":\"transitionPresence\",\"json\":\"" + json.Replace("\"", "\\\"") + "\"}");
            }
            object Controller() => receiver.GetType().GetField("presenceTransition", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(receiver);
            void AssertCalibratedTravel(float firstTime, float secondTime, float thirdTime, float startTime)
            {
                Invoke(Controller(), "Advance", startTime + firstTime, now + (long)(firstTime * 1000));
                Vector3 first = avatar.position;
                Invoke(Controller(), "Advance", startTime + secondTime, now + (long)(secondTime * 1000));
                Vector3 second = avatar.position;
                Invoke(Controller(), "Advance", startTime + thirdTime, now + (long)(thirdTime * 1000));
                Vector3 third = avatar.position;
                float speed = Vector3.Distance(first, second) / (secondTime - firstTime);
                Assert.That(Vector3.Distance(second, third) / (thirdTime - secondTime),
                    Is.EqualTo(speed).Within(.0001f), "Presence travel must not ease independently of the gait.");
                AnimationClip walk = animator.runtimeAnimatorController.animationClips.First(clip => clip.name == "standard_walk");
                Vector3 authored = walk.averageSpeed; authored.y = 0f;
                authored = animator.transform.TransformVector(authored); authored.y = 0f;
                float gaitSpeed = authored.magnitude * animator.humanScale * animator.GetFloat("WorldWalkSpeed");
                Assert.That(gaitSpeed, Is.EqualTo(speed).Within(.0001f),
                    "Home entry and exit must advance one authored stride's distance per cycle.");
            }
            Capture(camera, "home");
            Send("exit", "outbound", "left");
            Assert.That((bool)Controller().GetType().GetProperty("IsMoving").GetValue(Controller()), Is.True,
                "The default avatar must provide a real standard_walk Animator state.");
            animator.Update(0.35f);
            float start = (float)Controller().GetType().GetField("startedAt", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(Controller());
            AssertCalibratedTravel(.25f, .4f, .55f, start);
            Invoke(Controller(), "Advance", start + 0.55f, now + 550);
            vrm.Runtime.Process();
            Capture(camera, "walking-left");
            Assert.That(camera.transform.position, Is.EqualTo(cameraPosition));
            Assert.That(camera.transform.rotation, Is.EqualTo(cameraRotation));
            Invoke(Controller(), "Advance", start + 1.1f, now + 1100);
            Assert.That(animator.GetFloat("WorldWalkSpeed"), Is.EqualTo(1f));
            Assert.That(avatar.GetComponentsInChildren<Renderer>(true).All(renderer => renderer.forceRenderingOff), Is.True);
            Capture(camera, "empty-room");
            Send("prepare", "returning", "right");
            Send("enter", "returning", "right");
            start = (float)Controller().GetType().GetField("startedAt", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(Controller());
            AssertCalibratedTravel(.1f, .3f, .5f, start);
            Invoke(Controller(), "Advance", start + 1.1f, now + 2200);
            // This coarse test jumps directly to arrival. The visible walk's
            // speed must remain unchanged until its real idle blend completes.
            animator.Update(.21f);
            Invoke(Controller(), "Advance", start + 1.31f, now + 2410);
            Assert.That(animator.GetFloat("WorldWalkSpeed"), Is.EqualTo(1f));
            vrm.Runtime.Process();
            Assert.That(Vector3.Distance(avatar.position, homePosition), Is.LessThan(0.001f));
            Assert.That(avatar.GetComponentsInChildren<Renderer>(true).Any(renderer => !renderer.forceRenderingOff), Is.True);
            Capture(camera, "returned-home");
        }
        finally
        {
            Object.DestroyImmediate(room);
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        }
    }

    private static void Capture(Camera camera, string label)
    {
        if (SystemInfo.graphicsDeviceType == UnityEngine.Rendering.GraphicsDeviceType.Null) return;
        RenderTexture previous = camera.targetTexture;
        RenderTexture active = RenderTexture.active;
        var target = new RenderTexture(393, 852, 24, RenderTextureFormat.ARGB32);
        var image = new Texture2D(393, 852, TextureFormat.RGBA32, false);
        try
        {
            camera.targetTexture = target;
            camera.Render();
            RenderTexture.active = target;
            image.ReadPixels(new Rect(0, 0, 393, 852), 0, 0);
            image.Apply();
            string folder = Path.Combine(Path.GetTempPath(), "maaso-avatar-presence");
            Directory.CreateDirectory(folder);
            File.WriteAllBytes(Path.Combine(folder, label + ".png"), image.EncodeToPNG());
        }
        finally
        {
            camera.targetTexture = previous;
            RenderTexture.active = active;
            Object.DestroyImmediate(image);
            Object.DestroyImmediate(target);
        }
    }


    private static Type TypeOf(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    [Serializable]
    public sealed class AvatarPresenceCommand
    {
        public string requestId, transitionId, phase, edge;
        public int durationMs;
        public long sequence, expiresAtMs;
        public bool stationaryWalk, doNotInterrupt;
    }
    [Serializable]
    public sealed class AvatarPresenceResult
    {
        public string requestId, transitionId, phase, code;
        public bool ok;
    }
    private sealed class ControllerProxy
    {
        private readonly object target;
        public object Target => target;
        public ControllerProxy(List<AvatarPresenceResult> results)
        {
            Action<object> receive = value => results.Add(JsonUtility.FromJson<AvatarPresenceResult>(JsonUtility.ToJson(value)));
            Type resultType = TypeOf("AvatarPresenceResult");
            var parameter = Expression.Parameter(resultType);
            Delegate callback = Expression.Lambda(typeof(Action<>).MakeGenericType(resultType),
                Expression.Invoke(Expression.Constant(receive), Expression.Convert(parameter, typeof(object))), parameter).Compile();
            target = Activator.CreateInstance(TypeOf("AvatarPresenceTransitionController"), callback);
        }
        private object Call(string name, params object[] args) => target.GetType().GetMethod(name).Invoke(target, args);
        public bool OwnsPresentation => (bool)target.GetType().GetProperty("OwnsPresentation").GetValue(target);
        public bool IsHidden => (bool)target.GetType().GetProperty("IsHidden").GetValue(target);
        public void Advance(float now, long utc) => Call("Advance", now, utc);
        public void CancelForReset(string reason) => Call("CancelForReset", reason);
        public void Execute(AvatarPresenceCommand command, Transform avatar, Behaviour view, Func<bool> start, Action stop, float now, long utc) =>
            Call("Execute", JsonUtility.FromJson(JsonUtility.ToJson(command), TypeOf("AvatarPresenceCommand")), avatar, view, start, stop, now, utc);
    }

    private sealed class ReceiverFixture : IDisposable
    {
        public readonly Fixture Actor;
        public readonly Component Receiver;
        public readonly Vector3 Home;

        public ReceiverFixture()
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            Actor = new Fixture();
            Actor.Camera.tag = "MainCamera";
            Actor.SetFraming("hero_full_body");
            Home = Actor.Avatar.position;
            Receiver = new GameObject("Scene takeover receiver").AddComponent(TypeOf("UnityAvatarCommandReceiver"));
            void Set(string name, object value) => Receiver.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic).SetValue(Receiver, value);
            Set("avatarRoot", Actor.Avatar);
            Set("bundledAvatarRoot", Actor.Avatar);
            Set("presenceTransition", Actor.Controller.Target);
        }

        public void Start(bool opportunistic = true)
        {
            var prepare = Actor.Command("prepare"); prepare.doNotInterrupt = opportunistic; Actor.Execute(prepare);
            var enter = Actor.Command("enter", edge: "right"); enter.doNotInterrupt = opportunistic; Actor.Execute(enter);
            Actor.Controller.Advance(.35f, 1350);
        }

        public object Call(string name, params object[] args) => Receiver.GetType()
            .GetMethods(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
            .Single(method => method.Name == name && method.GetParameters().Length == args.Length).Invoke(Receiver, args);

        public void Send(string method, string json) => Call("OnFlutterCommand",
            "{\"method\":\"" + method + "\",\"json\":\"" + json.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"}");

        public void Dispose()
        {
            Object.DestroyImmediate(Receiver.gameObject);
            Actor.Dispose();
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        }
    }

    private sealed class Fixture : System.IDisposable
    {
        public readonly Transform Avatar;
        public readonly Renderer Mesh;
        public readonly Camera Camera;
        public readonly Behaviour View;
        public readonly List<AvatarPresenceResult> Results = new();
        public readonly ControllerProxy Controller;
        public bool CanWalk = true;
        public int Walks;
        public int Stops;
        private long sequence;

        public Fixture()
        {
            Avatar = new GameObject("Presence avatar").transform;
            GameObject body = GameObject.CreatePrimitive(PrimitiveType.Cube);
            body.transform.SetParent(Avatar, false);
            body.transform.localPosition = Vector3.up;
            body.transform.localScale = new Vector3(0.8f, 2f, 0.5f);
            Mesh = body.GetComponent<Renderer>();
            GameObject view = new("Presence camera");
            Camera = view.AddComponent<Camera>();
            View = (Behaviour)view.AddComponent(TypeOf("FrontFullBodyCamera"));
            View.GetType().GetProperty("TargetRoot").SetValue(View, Avatar);
            Camera.transform.position = new Vector3(0f, 1f, -5f);
            Camera.transform.rotation = Quaternion.identity;
            Camera.aspect = 0.46f;
            Controller = new ControllerProxy(Results);
        }

        public AvatarPresenceCommand Command(string phase, string transaction = "one", string edge = "left", bool stationary = false) => new()
        {
            requestId = "request-" + ++sequence, transitionId = transaction, phase = phase,
            edge = edge, durationMs = 1000, sequence = sequence, expiresAtMs = 10000, stationaryWalk = stationary,
        };
        public void Execute(string phase, string transaction = "one", string edge = "left", bool stationary = false) => Execute(Command(phase, transaction, edge, stationary));
        public void Execute(AvatarPresenceCommand command) => Controller.Execute(command, Avatar, View, () => { Walks++; return CanWalk; }, () => { Stops++; }, 0f, 1000);
        public string FramingMode => (string)View.GetType().GetProperty("FramingMode").GetValue(View);
        public void SetFraming(string mode) => View.GetType().GetMethod("SetFramingMode").Invoke(View, new object[] { mode });
        public void Dispose()
        {
            Controller.CancelForReset("test_finished");
            Object.DestroyImmediate(Avatar.gameObject);
            Object.DestroyImmediate(Camera.gameObject);
        }
    }
}

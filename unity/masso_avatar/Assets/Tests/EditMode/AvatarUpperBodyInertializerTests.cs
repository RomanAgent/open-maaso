using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using NUnit.Framework;
using UniVRM10;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.TestTools;
using Object = UnityEngine.Object;

public sealed class AvatarUpperBodyInertializerTests
{
    private static readonly Type Helper = Type.GetType("Maaso.Avatar.AvatarUpperBodyInertializer, Assembly-CSharp", true);
    private static object Call(object value, string method, params object[] args) => value.GetType().GetMethod(method).Invoke(value, args);
    private static Vector3 Decay(Vector3 value, Vector3 speed, float at, float length) =>
        (Vector3)Helper.GetMethod("Decay").Invoke(null, new object[] { value, speed, at, length });

    [Test]
    public void QuinticMatchesStartVelocityAndEndsAtRest()
    {
        Vector3 offset = new(.4f, -.2f, .1f), velocity = new(.8f, .3f, -.2f);
        Assert.That(Decay(offset, velocity, 0f, .28f), Is.EqualTo(offset));
        const float step = .0001f;
        Vector3 initialVelocity = (Decay(offset, velocity, step, .28f) - offset) / step;
        Assert.That(Vector3.Distance(initialVelocity, velocity), Is.LessThan(.003f));
        Assert.That(Decay(offset, velocity, .28f, .28f), Is.EqualTo(Vector3.zero));
        Assert.That(Decay(offset, velocity, .28f - step, .28f).magnitude / step, Is.LessThan(.02f));
    }

    [TestCase(30)]
    [TestCase(60)]
    [TestCase(12)]
    public void SameQuinticConvergesAtDifferentFrameRatesWithoutNan(int fps)
    {
        Vector3 start = new(.5f, .2f, -.1f), velocity = new(.2f, .1f, .3f);
        for (int frame = 0; frame <= fps; frame++)
        {
            Vector3 value = Decay(start, velocity, frame / (float)fps, .28f);
            Assert.That(float.IsNaN(value.sqrMagnitude) || float.IsInfinity(value.sqrMagnitude), Is.False);
            Assert.That(value.magnitude, Is.LessThan(.65f));
            if (frame / (float)fps >= .28f) Assert.That(value, Is.EqualTo(Vector3.zero));
        }
    }

    [Test]
    public void InvalidInputsFailClosed()
    {
        Assert.That(Decay(new Vector3(float.NaN, 0, 0), Vector3.zero, .1f, .28f), Is.EqualTo(Vector3.zero));
        Assert.That(Decay(Vector3.one, Vector3.zero, float.PositiveInfinity, .28f), Is.EqualTo(Vector3.zero));
        Assert.That(Decay(Vector3.one, Vector3.zero, .1f, 0f), Is.EqualTo(Vector3.zero));
    }

    [Test]
    public void RigMappingPreservesInitialPoseAndReleasesWithoutTouchingOtherChannels()
    {
        using var f = new Fixture();
        object helper = Activator.CreateInstance(Helper);
        Call(helper, "Bind", f.Animator);
        Assert.That((int)Helper.GetProperty("BoneCount").GetValue(helper), Is.GreaterThan(25));
        Transform arm = f.Animator.GetBoneTransform(HumanBodyBones.LeftUpperArm);
        Transform head = f.Animator.GetBoneTransform(HumanBodyBones.Head);
        Transform jaw = f.Animator.GetBoneTransform(HumanBodyBones.Jaw);
        Transform leg = f.Animator.GetBoneTransform(HumanBodyBones.LeftUpperLeg);
        Quaternion headBefore = head.localRotation, jawBefore = jaw.localRotation, legBefore = leg.localRotation;
        Vector3 actorBefore = f.Avatar.transform.position;
        Quaternion start = Quaternion.Euler(15, 0, 0), destination = Quaternion.Euler(45, 0, 0);
        arm.localRotation = start;
        Call(helper, "Apply", 1f, true);
        Call(helper, "RequestTransition");
        arm.localRotation = destination;
        Call(helper, "Apply", 1.02f, true);
        Assert.That(Quaternion.Angle(arm.localRotation, start), Is.LessThan(.05f), "A state change initially retains the outgoing arm.");
        if (f.Vrm != null)
        {
            Assert.That(arm, Is.EqualTo(f.Vrm.Runtime.ControlRig.GetBoneTransform(HumanBodyBones.LeftUpperArm)));
            Assert.That(f.Vrm.TryGetBoneTransform(HumanBodyBones.LeftUpperArm, out Transform raw), Is.True);
            Assert.That(raw, Is.Not.EqualTo(arm), "Runtime VRM correction belongs on its normalized rig, not double-written raw bones.");
            f.Vrm.Runtime.Process();
        }
        Call(helper, "RestoreBeforeAnimation");
        Assert.That(Quaternion.Angle(arm.localRotation, destination), Is.LessThan(.05f));
        arm.localRotation = destination;
        Call(helper, "Apply", 1.04f, true);
        Call(helper, "Reset");
        Assert.That(Quaternion.Angle(arm.localRotation, destination), Is.LessThan(.05f));
        Assert.That(Quaternion.Angle(head.localRotation, headBefore), Is.LessThan(.01f));
        Assert.That(Quaternion.Angle(jaw.localRotation, jawBefore), Is.LessThan(.01f));
        Assert.That(Quaternion.Angle(leg.localRotation, legBefore), Is.LessThan(.01f));
        Assert.That(f.Avatar.transform.position, Is.EqualTo(actorBefore));
    }

    [Test]
    public void RepeatedEvaluationDoesNotAccumulateAndNewOwnerIsNeverReverted()
    {
        using var f = new Fixture();
        object helper = Activator.CreateInstance(Helper);
        Call(helper, "Bind", f.Animator);
        Transform arm = f.Animator.GetBoneTransform(HumanBodyBones.RightUpperArm);
        arm.localRotation = Quaternion.identity;
        Call(helper, "Apply", 0f, true);
        Call(helper, "RequestTransition");
        Quaternion destination = Quaternion.Euler(0, 0, 35);
        arm.localRotation = destination;
        Call(helper, "Apply", .02f, true);
        Quaternion first = arm.localRotation;
        Call(helper, "Apply", .02f, true);
        Assert.That(Quaternion.Angle(arm.localRotation, first), Is.LessThan(.01f));
        Quaternion phoneOwned = Quaternion.Euler(0, 50, 5);
        arm.localRotation = phoneOwned;
        Call(helper, "Reset");
        Assert.That(Quaternion.Angle(arm.localRotation, phoneOwned), Is.LessThan(.01f), "Cancel must not undo a later IK or task owner.");
    }

    [Test]
    public void ContinuousSourceMaintainsVelocityAndReachesExactSource()
    {
        using var f = new Fixture();
        object helper = Activator.CreateInstance(Helper);
        Call(helper, "Bind", f.Animator);
        Transform arm = f.Animator.GetBoneTransform(HumanBodyBones.LeftLowerArm);
        arm.localRotation = Quaternion.Euler(0, 0, 0); Call(helper, "Apply", 0f, true);
        arm.localRotation = Quaternion.Euler(0, 0, 1); Call(helper, "Apply", .02f, true);
        Call(helper, "RequestTransition");
        arm.localRotation = Quaternion.Euler(0, 0, 2); Call(helper, "Apply", .04f, true);
        Quaternion previous = arm.localRotation;
        Call(helper, "RestoreBeforeAnimation");
        arm.localRotation = Quaternion.Euler(0, 0, 3); Call(helper, "Apply", .06f, true);
        float step = Quaternion.Angle(previous, arm.localRotation);
        Assert.That(step, Is.InRange(.8f, 1.2f), "An already continuous Animator blend must not gain spurious angular velocity.");
        for (int i = 4; i <= 25; i++)
        {
            Call(helper, "RestoreBeforeAnimation");
            arm.localRotation = Quaternion.Euler(0, 0, i);
            Call(helper, "Apply", i * .02f, true);
        }
        Assert.That((bool)Helper.GetProperty("Transitioning").GetValue(helper), Is.False);
        Assert.That(Quaternion.Angle(arm.localRotation, Quaternion.Euler(0, 0, 25)), Is.LessThan(.01f));
    }

    [Test]
    public void BlockedModelReplacementAndLongClockGapReleaseSafely()
    {
        using var f = new Fixture();
        object helper = Activator.CreateInstance(Helper);
        Call(helper, "Bind", f.Animator);
        Transform arm = f.Animator.GetBoneTransform(HumanBodyBones.LeftUpperArm);
        arm.localRotation = Quaternion.identity; Call(helper, "Apply", 0f, true);
        Call(helper, "RequestTransition");
        Quaternion destination = Quaternion.Euler(30, 0, 0);
        arm.localRotation = destination; Call(helper, "Apply", .02f, true);
        Call(helper, "Apply", .03f, false);
        Assert.That(Quaternion.Angle(arm.localRotation, destination), Is.LessThan(.01f));
        Call(helper, "RequestTransition"); Call(helper, "Apply", 2f, true);
        Assert.That((bool)Helper.GetProperty("Transitioning").GetValue(helper), Is.False);
        Call(helper, "Bind", new object[] { null });
        Assert.That((int)Helper.GetProperty("BoneCount").GetValue(helper), Is.Zero);
    }

    [TestCase(30)]
    [TestCase(60)]
    public void MeasuredStateDiscontinuityIsReducedAtBothShippingRates(int fps)
    {
        using var f = new Fixture();
        object helper = Activator.CreateInstance(Helper);
        Call(helper, "Bind", f.Animator);
        Transform arm = f.Animator.GetBoneTransform(HumanBodyBones.RightLowerArm);
        arm.localRotation = Quaternion.identity; Call(helper, "Apply", 0f, true);
        Call(helper, "RequestTransition");
        Quaternion source = Quaternion.Euler(0, 30, 0), previous = Quaternion.identity;
        float largestStep = 0f;
        for (int frame = 1; frame <= fps; frame++)
        {
            Call(helper, "RestoreBeforeAnimation");
            arm.localRotation = source;
            Call(helper, "Apply", frame / (float)fps, true);
            largestStep = Mathf.Max(largestStep, Quaternion.Angle(previous, arm.localRotation));
            previous = arm.localRotation;
        }
        TestContext.WriteLine($"Upper-body {fps}fps: raw switch 30deg; corrected maximum step {largestStep:R}deg");
        Assert.That(largestStep, Is.LessThan(230f / fps));
        Assert.That(Quaternion.Angle(arm.localRotation, source), Is.LessThan(.01f));
    }

    [Test]
    public void LateSelectedStateWaitsForNextAnimatorEvaluationBeforeCapturingOffset()
    {
        using var f = new Fixture();
        object helper = Activator.CreateInstance(Helper);
        Call(helper, "Bind", f.Animator);
        Transform arm = f.Animator.GetBoneTransform(HumanBodyBones.LeftUpperArm);
        arm.localRotation = Quaternion.identity;
        Call(helper, "Apply", 0f, true);
        // Animator already produced this frame. A LateUpdate state selection
        // must not consume its request using those unchanged old transforms.
        Call(helper, "RequestTransitionAfterEvaluation");
        Call(helper, "RestoreBeforeAnimation");
        Call(helper, "Apply", .02f, true);
        Assert.That((bool)Helper.GetProperty("Transitioning").GetValue(helper), Is.False);
        Call(helper, "BeforeAnimatorEvaluation");
        Quaternion destination = Quaternion.Euler(30f, 0f, 0f);
        arm.localRotation = destination; // the next Animator evaluation
        Call(helper, "Apply", .04f, true);
        Assert.That((bool)Helper.GetProperty("Transitioning").GetValue(helper), Is.True);
        Assert.That(Quaternion.Angle(arm.localRotation, Quaternion.identity), Is.LessThan(.01f));
        Call(helper, "BeforeAnimatorEvaluation");
        Assert.That(Quaternion.Angle(arm.localRotation, destination), Is.LessThan(.01f));
        arm.localRotation = destination;
        Call(helper, "Apply", .06f, true);
        Assert.That(Quaternion.Angle(arm.localRotation, destination), Is.GreaterThan(20f));
    }

    [TestCase(30, false)]
    [TestCase(60, false)]
    [TestCase(30, true)]
    [TestCase(60, true)]
    public void DifferentSourceSmallPoseJumpCannotBecomeAnOppositeAngularImpulse(int fps, bool deferred)
    {
        using var f = new Fixture();
        object helper = Activator.CreateInstance(Helper);
        Call(helper, "Bind", f.Animator);
        Transform arm = f.Animator.GetBoneTransform(HumanBodyBones.LeftLowerArm);
        float dt = 1f / fps;
        arm.localRotation = Quaternion.identity; Call(helper, "Apply", 0f, true);
        arm.localRotation = Quaternion.identity; Call(helper, "Apply", dt, true);
        Call(helper, deferred ? "RequestSourceTransitionAfterEvaluation" : "RequestSourceTransition");
        if (deferred) Call(helper, "BeforeAnimatorEvaluation");
        Quaternion target = Quaternion.Euler(0f, 0f, 10f);
        arm.localRotation = target; Call(helper, "Apply", 2f * dt, true);
        Assert.That(Quaternion.Angle(arm.localRotation, Quaternion.identity), Is.LessThan(.05f));
        float previous = 0f, maximumStep = 0f;
        for (int frame = 1; frame <= fps; frame++)
        {
            Call(helper, "BeforeAnimatorEvaluation");
            arm.localRotation = target;
            Call(helper, "Apply", (frame + 2f) * dt, true);
            float angle = Mathf.DeltaAngle(0f, arm.localEulerAngles.z);
            Assert.That(angle, Is.InRange(-.02f, 10.02f),
                "A cross-source 10deg jump is an offset, not 10deg/dt incoming velocity.");
            Assert.That(angle + .02f, Is.GreaterThanOrEqualTo(previous), "The static destination must not first kick away.");
            maximumStep = Mathf.Max(maximumStep, Mathf.Abs(angle - previous)); previous = angle;
        }
        Assert.That(maximumStep, Is.LessThan(60f / fps));
        Assert.That(Quaternion.Angle(arm.localRotation, target), Is.LessThan(.01f));
        TestContext.WriteLine("Source identity switch 10deg, " + fps + "fps, deferred=" + deferred +
            "; maximum step degrees=" + maximumStep + "; final=" + previous);
    }

    [TestCase(30, 10f)]
    [TestCase(60, 10f)]
    [TestCase(30, 100f)]
    [TestCase(60, 100f)]
    public void OnlyLargeSourceOffsetsExtendTheirReleaseAndAllSettleBeforeSixTenths(int fps, float degrees)
    {
        using var f = new Fixture();
        object helper = Activator.CreateInstance(Helper);
        Call(helper, "Bind", f.Animator);
        Transform arm = f.Animator.GetBoneTransform(HumanBodyBones.LeftUpperArm);
        arm.localRotation = Quaternion.identity; Call(helper, "Apply", 0f, true);
        Call(helper, "RequestSourceTransition");
        Quaternion target = Quaternion.Euler(0f, 0f, degrees), previous = Quaternion.identity;
        float maximumStep = 0f;
        for (int frame = 1; frame <= fps; frame++)
        {
            Call(helper, "BeforeAnimatorEvaluation");
            arm.localRotation = target;
            float now = frame / (float)fps;
            Call(helper, "Apply", now, true);
            maximumStep = Mathf.Max(maximumStep, Quaternion.Angle(previous, arm.localRotation));
            previous = arm.localRotation;
            if (frame == Mathf.RoundToInt(.4f * fps))
                Assert.That((bool)Helper.GetProperty("Transitioning").GetValue(helper), Is.EqualTo(degrees > 10f),
                    "Small source offsets retain .36s; a 100deg handoff receives more release time.");
            if (now >= .6f)
            {
                Assert.That((bool)Helper.GetProperty("Transitioning").GetValue(helper), Is.False);
                Assert.That(Quaternion.Angle(arm.localRotation, target), Is.LessThan(.02f));
            }
        }
        Assert.That(maximumStep, Is.LessThan(350f / fps), "The tested static handoff should follow the correction-speed target.");
        TestContext.WriteLine("Source offset=" + degrees + "deg at " + fps + "fps; maximum step=" + maximumStep);
    }

    [Test]
    public void TaskResetDropsDeferredRequestBeforeNextEvaluation()
    {
        using var f = new Fixture();
        object helper = Activator.CreateInstance(Helper);
        Call(helper, "Bind", f.Animator);
        Call(helper, "Apply", 0f, true);
        Call(helper, "RequestTransitionAfterEvaluation");
        Call(helper, "Reset");
        Call(helper, "BeforeAnimatorEvaluation");
        Call(helper, "Apply", .02f, true);
        Assert.That((bool)Helper.GetProperty("Transitioning").GetValue(helper), Is.False);
    }

    [TestCase(30)]
    [TestCase(60)]
    public void UnchangedMotionSourceKeepsFastAuthoredFramesWithoutAnOutputRateLimit(int fps)
    {
        using var f = new Fixture();
        object helper = Activator.CreateInstance(Helper);
        Call(helper, "Bind", f.Animator);
        Transform arm = f.Animator.GetBoneTransform(HumanBodyBones.LeftLowerArm);
        Transform jaw = f.Animator.GetBoneTransform(HumanBodyBones.Jaw);
        Transform leg = f.Animator.GetBoneTransform(HumanBodyBones.LeftUpperLeg);
        Quaternion jawBefore = jaw.localRotation, legBefore = leg.localRotation;
        Vector3 rootBefore = f.Avatar.transform.position;
        arm.localRotation = Quaternion.identity; Call(helper, "Apply", 0f, true);
        Quaternion previous = arm.localRotation;
        float estimateLimit = (float)Helper.GetField("MaximumAngularSpeed").GetValue(null);
        float measuredMaxSpeed = 0f;
        Quaternion target = Quaternion.identity;
        for (int frame = 1; frame <= 90; frame++)
        {
            Call(helper, "BeforeAnimatorEvaluation");
            // This is a genuine fast source, not a state switch. A display
            // velocity limiter must never silently replace these authored keys.
            target = Quaternion.Euler(frame % 2 == 0 ? 110f : -100f, 30f, frame * 7f);
            arm.localRotation = target;
            Call(helper, "Apply", frame / (float)fps, true);
            Assert.That(Quaternion.Angle(arm.localRotation, target), Is.LessThan(.01f), "Every source key must be retained at frame " + frame);
            float speed = Quaternion.Angle(previous, arm.localRotation) * Mathf.Deg2Rad * fps;
            measuredMaxSpeed = Mathf.Max(measuredMaxSpeed, speed);
            previous = arm.localRotation;
        }
        Assert.That(measuredMaxSpeed, Is.GreaterThan(estimateLimit), "The fixture must actually exceed the estimate guard and former output limiter.");
        Assert.That(Quaternion.Angle(jaw.localRotation, jawBefore), Is.LessThan(.01f));
        Assert.That(Quaternion.Angle(leg.localRotation, legBefore), Is.LessThan(.01f));
        Assert.That(f.Avatar.transform.position, Is.EqualTo(rootBefore));
    }

    [Test]
    public void TaskTakeoverAndItsNewPoseImmediatelyDiscardSourceSwitchOffsets()
    {
        using var f = new Fixture();
        object helper = Activator.CreateInstance(Helper);
        Call(helper, "Bind", f.Animator);
        Transform arm = f.Animator.GetBoneTransform(HumanBodyBones.RightLowerArm);
        arm.localRotation = Quaternion.identity; Call(helper, "Apply", 0f, true);
        Call(helper, "RequestTransition");
        Quaternion fastSource = Quaternion.Euler(0f, 140f, 0f);
        arm.localRotation = fastSource; Call(helper, "Apply", 1f / 60f, true);
        Assert.That(Quaternion.Angle(arm.localRotation, fastSource), Is.GreaterThan(100f), "This case must actually engage a source-switch offset before takeover.");
        Call(helper, "Apply", 2f / 60f, false);
        Assert.That(Quaternion.Angle(arm.localRotation, fastSource), Is.LessThan(.02f), "A task releases the correction immediately.");
        Quaternion taskPose = Quaternion.Euler(-130f, 20f, 5f);
        arm.localRotation = taskPose;
        Call(helper, "Apply", 3f / 60f, false);
        Assert.That(Quaternion.Angle(arm.localRotation, taskPose), Is.LessThan(.02f));
        Call(helper, "BeforeAnimatorEvaluation"); Call(helper, "Apply", 4f / 60f, true);
        Assert.That(Quaternion.Angle(arm.localRotation, taskPose), Is.LessThan(.02f), "Resuming samples the new owner pose rather than catching up from stale body history.");
    }

    [TestCase(30)]
    [TestCase(60)]
    public void LargeSourceSwitchStartsAtShownPoseAndSettlesWithoutAClampedTeleport(int fps)
    {
        using var f = new Fixture();
        object helper = Activator.CreateInstance(Helper);
        Call(helper, "Bind", f.Animator);
        Transform arm = f.Animator.GetBoneTransform(HumanBodyBones.LeftUpperArm);
        Quaternion outgoing = Quaternion.identity, incoming = Quaternion.Euler(0f, 150f, 0f);
        arm.localRotation = outgoing; Call(helper, "Apply", 0f, true);
        Call(helper, "RequestTransition");
        arm.localRotation = incoming; Call(helper, "Apply", 1f / fps, true);
        Assert.That(Quaternion.Angle(arm.localRotation, outgoing), Is.LessThan(.02f),
            "A 55-degree offset cap discarded most of this source switch before smoothing began.");
        Quaternion previous = arm.localRotation;
        float maximumStep = 0f;
        for (int frame = 2; frame <= fps; frame++)
        {
            Call(helper, "BeforeAnimatorEvaluation"); arm.localRotation = incoming;
            Call(helper, "Apply", frame / (float)fps, true);
            maximumStep = Mathf.Max(maximumStep, Quaternion.Angle(previous, arm.localRotation));
            previous = arm.localRotation;
        }
        float seconds = (float)Helper.GetField("TransitionSeconds").GetValue(null);
        // The zero-velocity quintic's maximum normalized derivative is1.875.
        // This checks switch continuity without capping real source velocities.
        float quinticMaximumStep = Quaternion.Angle(outgoing, incoming) * 1.875f / seconds / fps;
        Assert.That(maximumStep, Is.LessThanOrEqualTo(quinticMaximumStep + .1f));
        Assert.That(Quaternion.Angle(arm.localRotation, incoming), Is.LessThan(.02f));
        Assert.That((bool)Helper.GetProperty("Transitioning").GetValue(helper), Is.False);
    }

    [TestCase(30)]
    [TestCase(60)]
    public void PresentedOrdinaryOverlayExitStartsAtShownPoseAndSettles(int fps)
    {
        using var f = new Fixture();
        object helper = Activator.CreateInstance(Helper);
        Call(helper, "Bind", f.Animator);
        Transform arm = f.Animator.GetBoneTransform(HumanBodyBones.LeftUpperArm);
        Quaternion source = Quaternion.identity, presented = Quaternion.Euler(0f, 0f, 20f);
        Vector3 actor = f.Avatar.transform.position;
        arm.localRotation = source; Call(helper, "Apply", 0f, true);
        // This is the final normalized pose after the collision overlay. A
        // separate capture must retain it after that overlay restores its write.
        arm.localRotation = presented; Call(helper, "CapturePresentedPose");
        Call(helper, "BeforeAnimatorEvaluation"); arm.localRotation = source;
        Call(helper, "RequestPresentedTransition");
        Call(helper, "Apply", 1f / fps, true);
        Assert.That(Quaternion.Angle(arm.localRotation, presented), Is.LessThan(.05f),
            "Ordinary overlay release begins at what was shown, not the earlier pre-IK Animator sample.");
        Quaternion previous = arm.localRotation;
        float maximumStep = 0f;
        for (int frame = 2; frame <= fps; frame++)
        {
            Call(helper, "BeforeAnimatorEvaluation"); arm.localRotation = source;
            Call(helper, "Apply", frame / (float)fps, true);
            maximumStep = Mathf.Max(maximumStep, Quaternion.Angle(previous, arm.localRotation));
            previous = arm.localRotation;
            Call(helper, "CapturePresentedPose");
        }
        TestContext.WriteLine("Joy normalized" + " presented release " + fps + "fps max step deg=" + maximumStep);
        Assert.That(maximumStep, Is.LessThan(150f / fps), "The 20-degree release must be continuous rather than a one-frame drop.");
        Assert.That(Quaternion.Angle(arm.localRotation, source), Is.LessThan(.02f));
        Assert.That((bool)Helper.GetProperty("Transitioning").GetValue(helper), Is.False);
        Assert.That(f.Avatar.transform.position, Is.EqualTo(actor));
    }

    [Test]
    public void CapturingOngoingOverlayDoesNotFeedItBackIntoOrdinaryAnimatorOutput()
    {
        using var f = new Fixture();
        object helper = Activator.CreateInstance(Helper);
        Call(helper, "Bind", f.Animator);
        Transform arm = f.Animator.GetBoneTransform(HumanBodyBones.RightLowerArm);
        Quaternion source = Quaternion.identity, overlay = Quaternion.Euler(0f, 23f, 0f);
        arm.localRotation = source; Call(helper, "Apply", 0f, true);
        for (int frame = 1; frame <= 90; frame++)
        {
            Call(helper, "BeforeAnimatorEvaluation"); arm.localRotation = source;
            Call(helper, "Apply", frame / 60f, true);
            Assert.That(Quaternion.Angle(arm.localRotation, source), Is.LessThan(.02f),
                "A capture without a release request cannot alter or accumulate the normal source at frame " + frame);
            arm.localRotation = overlay; Call(helper, "CapturePresentedPose");
        }
    }

    [Test]
    public void TaskTakeoverImmediatelyDiscardsPresentedReleaseAndItsCapturedHistory()
    {
        using var f = new Fixture();
        object helper = Activator.CreateInstance(Helper);
        Call(helper, "Bind", f.Animator);
        Transform arm = f.Animator.GetBoneTransform(HumanBodyBones.LeftLowerArm);
        arm.localRotation = Quaternion.identity; Call(helper, "Apply", 0f, true);
        Quaternion presented = Quaternion.Euler(0f, 25f, 0f);
        arm.localRotation = presented; Call(helper, "CapturePresentedPose");
        Call(helper, "BeforeAnimatorEvaluation"); arm.localRotation = Quaternion.identity;
        Call(helper, "RequestPresentedTransition"); Call(helper, "Apply", 1f / 60f, true);
        Assert.That((bool)Helper.GetProperty("Transitioning").GetValue(helper), Is.True);
        Quaternion task = Quaternion.Euler(-110f, 13f, 8f);
        arm.localRotation = task;
        Call(helper, "Apply", 2f / 60f, false);
        Assert.That(Quaternion.Angle(arm.localRotation, task), Is.LessThan(.02f), "A real task owns its pose immediately.");
        Assert.That((bool)Helper.GetProperty("Transitioning").GetValue(helper), Is.False);
        Call(helper, "RequestPresentedTransition");
        Call(helper, "BeforeAnimatorEvaluation"); Call(helper, "Apply", 3f / 60f, true);
        Assert.That(Quaternion.Angle(arm.localRotation, task), Is.LessThan(.02f), "Resume cannot resurrect a stale post-guard pose after task reset.");
    }

    private sealed class Fixture : IDisposable
    {
        public readonly GameObject Avatar;
        public readonly Animator Animator;
        public readonly Vrm10Instance Vrm;
        private readonly Dictionary<Renderer, Material[]> originalMaterials;
        public Fixture()
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            Avatar = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm"));
            originalMaterials = Avatar.GetComponentsInChildren<Renderer>()
                .Where(renderer => renderer is SkinnedMeshRenderer || renderer is MeshRenderer)
                .ToDictionary(renderer => renderer, renderer => renderer.sharedMaterials);
            Animator = Avatar.GetComponentInChildren<Animator>(true);
            {
                Vrm = Avatar.GetComponentInChildren<Vrm10Instance>(true);
                typeof(Vrm10Instance).GetField("m_useControlRig", BindingFlags.Instance | BindingFlags.NonPublic).SetValue(Vrm, true);
                // Pinned UniVRM's real expression runtime clones every non-null
                // material slot on an editor-imported prefab. Match only this
                // known SDK diagnostic; all other errors continue to fail.
                int slots = originalMaterials.Values.Sum(materials => materials.Count(material => material != null));
                Assert.That(slots, Is.EqualTo(17), "Reviewed Joy material inventory changed.");
                for (int slot = 0; slot < slots; slot++)
                    LogAssert.Expect(LogType.Error,
                        "Instantiating material due to calling renderer.material during edit mode. This will leak materials into the scene. You most likely want to use renderer.sharedMaterial instead.");
                Assert.That(Vrm.Runtime.ControlRig, Is.Not.Null);
            }
            Assert.That(Animator.isHuman, Is.True);
        }
        public void Dispose()
        {
            var borrowed = new HashSet<Material>(originalMaterials.Values.SelectMany(materials => materials));
            Material[] clones = originalMaterials.Keys.Where(renderer => renderer != null)
                .SelectMany(renderer => renderer.sharedMaterials)
                .Where(material => material != null && !borrowed.Contains(material) && !AssetDatabase.Contains(material))
                .Distinct().ToArray();
            foreach (var pair in originalMaterials)
                if (pair.Key != null) pair.Key.sharedMaterials = pair.Value;
            foreach (Material clone in clones) Object.DestroyImmediate(clone);
            // UniVRM releases generated runtime objects with play-mode Destroy.
            // This fixture owns a temporary edit-mode rig; retire those objects
            // immediately before disposing its imported owner.
            if (Vrm != null && Vrm.Runtime.ControlRig != null)
            {
                Object.DestroyImmediate(Vrm.Runtime.ControlRig.ControlRigAnimator.avatar);
                Transform controlRoot = Vrm.transform.Find("Runtime Control Rig");
                if (controlRoot != null) Object.DestroyImmediate(controlRoot.gameObject);
            }
            Object.DestroyImmediate(Avatar);
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        }
    }
}

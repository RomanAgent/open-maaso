using System;
using System.Linq;
using System.Reflection;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.Animations;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.TestTools;

public sealed class WorldLocomotionPresentationTests
{
    private static Type Subject => Type.GetType(
        "Maaso.World.WorldLocomotionPresentation, Assembly-CSharp");

    [Test]
    public void FacingPointsAlongPlanarDestinationAndIgnoresHeight()
    {
        Assert.That(Subject, Is.Not.Null);
        MethodInfo method = Subject.GetMethod(
            "ResolveFacing",
            BindingFlags.Public | BindingFlags.Static);

        Quaternion east = (Quaternion)method.Invoke(
            null,
            new object[]
            {
                Vector3.zero,
                new Vector3(4f, 9f, 0f),
                Quaternion.identity,
            });
        Assert.That(
            Vector3.Dot(east * Vector3.forward, Vector3.right),
            Is.GreaterThan(0.999f));

        Quaternion north = (Quaternion)method.Invoke(
            null,
            new object[]
            {
                Vector3.zero,
                new Vector3(0f, -3f, 4f),
                Quaternion.identity,
            });
        Assert.That(
            Vector3.Dot(north * Vector3.forward, Vector3.forward),
            Is.GreaterThan(0.999f));
    }

    [Test]
    public void MovementUsesDifferentStartAndStopThresholds()
    {
        Assert.That(Subject, Is.Not.Null);
        MethodInfo method = Subject.GetMethod(
            "ShouldMove",
            BindingFlags.Public | BindingFlags.Static);

        Assert.That(
            method.Invoke(
                null,
                new object[] { Vector3.zero, Vector3.right * 0.1f, false }),
            Is.True);
        Assert.That(
            method.Invoke(
                null,
                new object[] { Vector3.zero, Vector3.right * 0.05f, false }),
            Is.False);
        Assert.That(
            method.Invoke(
                null,
                new object[] { Vector3.zero, Vector3.right * 0.05f, true }),
            Is.True);
        Assert.That(
            method.Invoke(
                null,
                new object[] { Vector3.zero, Vector3.right * 0.01f, true }),
            Is.False);
    }

    [Test]
    public void AdvancePositionUsesFixedWalkingDistanceForLongTravel()
    {
        Assert.That(Subject, Is.Not.Null);
        MethodInfo method = Subject.GetMethod(
            "AdvancePosition",
            BindingFlags.Public | BindingFlags.Static);
        Assert.That(method, Is.Not.Null);

        Vector3 next = (Vector3)method.Invoke(
            null,
            new object[]
            {
                Vector3.zero,
                Vector3.right * 10f,
                0.25f,
            });

        Assert.That(next.x, Is.EqualTo(0.46f).Within(0.0001f));
        Assert.That(next.y, Is.EqualTo(0f));
        Assert.That(next.z, Is.EqualTo(0f));
    }

    [Test]
    public void AdvanceRotationLimitsFacingToConfiguredDegreesPerSecond()
    {
        Assert.That(Subject, Is.Not.Null);
        MethodInfo method = Subject.GetMethod(
            "AdvanceRotation",
            BindingFlags.Public | BindingFlags.Static);
        Assert.That(method, Is.Not.Null);

        Quaternion next = (Quaternion)method.Invoke(
            null,
            new object[]
            {
                Quaternion.identity,
                Quaternion.Euler(0f, 90f, 0f),
                0.1f,
            });

        Assert.That(
            Quaternion.Angle(Quaternion.identity, next),
            Is.EqualTo(36f).Within(0.0001f));
    }

    [Test]
    public void StandardWalkClipLoopsForTheFullLocomotionDuration()
    {
        AnimationClip standardWalk = AssetDatabase.LoadAssetAtPath<AnimationClip>(
            "Assets/MaasoAvatar/Animations/Humanoid/Actions/standard_walk.anim");

        Assert.That(standardWalk, Is.Not.Null);
        Assert.That(
            AnimationUtility.GetAnimationClipSettings(standardWalk).loopTime,
            Is.True);
    }

    [TestCase(1f)]
    [TestCase(2f)]
    public void WalkingPlaybackMatchesWorldDistanceForBundledAvatar(float scale)
    {
        GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(
            "Assets/MaasoAvatar/Models/Default/Joy.vrm");
        AnimationClip clip = AssetDatabase.LoadAssetAtPath<AnimationClip>(
            "Assets/MaasoAvatar/Animations/Humanoid/Actions/standard_walk.anim");
        RuntimeAnimatorController controller =
            AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>(
                "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller");
        Assert.That(prefab, Is.Not.Null);
        Assert.That(clip, Is.Not.Null);
        Assert.That(controller, Is.Not.Null);
        var receiverHost = new GameObject("WorldWalkSpeedReceiver");
        GameObject avatar = UnityEngine.Object.Instantiate(prefab);

        try
        {
            avatar.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            avatar.transform.localScale = Vector3.one * scale;
            Animator animator = avatar.GetComponentInChildren<Animator>(true);
            Assert.That(animator, Is.Not.Null);
            animator.runtimeAnimatorController = controller;
            animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            // Root motion is enabled only as an independent distance reference.
            // The actual world keeps it disabled and advances the owner instead.
            animator.applyRootMotion = true;
            animator.Rebind();
            Type receiverType = Type.GetType(
                "Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp");
            Assert.That(receiverType, Is.Not.Null);
            Component receiver = receiverHost.AddComponent(receiverType);
            var serialized = new SerializedObject(receiver);
            serialized.FindProperty("avatarRoot").objectReferenceValue = avatar.transform;
            serialized.FindProperty("animator").objectReferenceValue = animator;
            serialized.ApplyModifiedPropertiesWithoutUndo();
            MethodInfo setLocomotion = receiverType.GetMethod("SetWorldLocomotion");
            Assert.That(setLocomotion, Is.Not.Null);
            setLocomotion.Invoke(receiver, new object[] { true });

            float playbackSpeed = animator.GetFloat("WorldWalkSpeed");
            Assert.That(playbackSpeed, Is.GreaterThan(0f));
            Assert.That(animator.speed, Is.EqualTo(1f),
                "Walking calibration must not change the speed of gestures and idle states.");

            animator.Play("standard_walk", 0, 0f);
            animator.Update(0f);
            Vector3 start = avatar.transform.position;
            float cycleSeconds = clip.length / playbackSpeed;
            for (int frame = 0; frame < 120; frame++)
            {
                animator.Update(cycleSeconds / 120f);
            }

            Vector3 displacement = avatar.transform.position - start;
            displacement.y = 0f;
            float expectedDistance = 1.84f * cycleSeconds;
            Assert.That(
                displacement.magnitude,
                Is.EqualTo(expectedDistance).Within(expectedDistance * 0.025f + 0.005f),
                "One authored stride must cover the same distance as world navigation at this avatar scale.");

            setLocomotion.Invoke(receiver, new object[] { false });
            Assert.That(animator.GetFloat("WorldWalkSpeed"), Is.EqualTo(1f));
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(receiverHost);
            UnityEngine.Object.DestroyImmediate(avatar);
        }
    }

    [TestCase(0.12f, 0f, 0.4f, 0.4f)]
    [TestCase(0.8f, 0f, 0.4f, 0.8f)]
    [TestCase(0.16f, 0.45f, 0.4f, 0.8f)]
    public void ArrivalIsAtLeastOneFootfallAndKeepsTheExistingStrideClock(
        float distance, float elapsed, float step, float expected)
    {
        MethodInfo method = Subject.GetMethod("ArrivalAtStepBoundary");
        Assert.That((float)method.Invoke(null, new object[] { distance, elapsed, step }),
            Is.EqualTo(expected).Within(.00001f));
    }

    [TestCase(.12f)]
    [TestCase(.65f)]
    [TestCase(2.2f)]
    public void PlannedStepDistanceMatchesTheActualBlendedGait(float distance)
    {
        using var f = new OwnerStepFixture();
        Vector3 target = f.Owner.position + Vector3.right * distance;
        f.Target(target);
        float stepSeconds = f.Field<float>("walkingStepSeconds");
        float arrival = f.Field<float>("targetArrivalElapsed");
        float plannedStepDistance = distance * stepSeconds / arrival;
        float stride = f.Animator.GetFloat("WorldWalkStride");
        Assert.That(stride, Is.EqualTo(distance / (arrival * 1.84f)).Within(.00001f),
            "A full walk pose must not be squeezed into a shorter ground displacement.");

        // Measure an independent clone with Unity's own root motion enabled.
        // This checks the authored gait rather than repeating the path formula.
        GameObject reference = UnityEngine.Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>(
            "Assets/MaasoAvatar/Models/Default/Joy.vrm"));
        try
        {
            reference.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            Animator animator = reference.GetComponentInChildren<Animator>(true);
            animator.runtimeAnimatorController = f.Animator.runtimeAnimatorController;
            animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            animator.applyRootMotion = true;
            animator.Rebind();
            animator.SetFloat("WorldWalkSpeed", f.Animator.GetFloat("WorldWalkSpeed"));
            animator.SetFloat("WorldWalkStride", stride);
            animator.Play("standard_walk", 0, 0f);
            animator.Update(0f);
            Vector3 origin = reference.transform.position;
            // Two alternating steps cancel minor per-foot asymmetry.
            for (int frame = 0; frame < 240; frame++) animator.Update(stepSeconds * 2f / 240f);
            Vector3 traveled = reference.transform.position - origin;
            traveled.y = 0f;
            Assert.That(animator.GetCurrentAnimatorStateInfo(0).normalizedTime, Is.EqualTo(1f).Within(.005f),
                "Stride amplitude must leave the gait's half-cycle clock unchanged.");
            Assert.That(traveled.magnitude * .5f, Is.EqualTo(plannedStepDistance).Within(.025f),
                "The visible blended stride and owner travel must agree within 2.5 cm.");
        }
        finally { UnityEngine.Object.DestroyImmediate(reference); }

        for (int frame = 0; frame < 600 && f.IsWalking; frame++) f.Advance(1f / 120f);
        Assert.That(f.IsWalking, Is.False);
        Assert.That(Vector3.Distance(f.Owner.position, target), Is.LessThan(.00001f));
        Assert.That(f.Animator.GetFloat("WorldWalkStride"), Is.EqualTo(1f),
            "A later Home or ordinary walk must recover the full authored stride.");
    }

    [Test]
    public void LongWalkRootTravelDoesNotPulseWithAnimatorCrossFade()
    {
        using var f = new OwnerStepFixture();
        Vector3 destination = f.Owner.position + Vector3.right * 2.2f;
        f.Target(destination);
        var deltas = new System.Collections.Generic.List<float>();
        for (int frame = 0; frame < 240 && f.IsWalking; frame++)
        {
            Vector3 before = f.Owner.position;
            float remaining = Vector3.Distance(before, destination);
            f.Advance(1f / 60f);
            if (remaining > .35f) deltas.Add(Vector3.Distance(before, f.Owner.position));
        }
        Assert.That(deltas.Count, Is.GreaterThan(20));
        int stalled = deltas.Count(value => value < .001f);
        float biggest = deltas.Max();
        Assert.That(stalled, Is.LessThanOrEqualTo(1),
            "A visible walk must not repeatedly pause while Animator crossfades: " + string.Join(",", deltas.Take(20)));
        Assert.That(biggest, Is.LessThan(.05f),
            "One 60 Hz frame must not jump farther than about two normal walking frames.");
        Assert.That(Vector3.Distance(f.Owner.position, destination), Is.LessThan(.0001f));
    }

    [Test]
    public void OwnerTravelRemainsSmoothWhenAnimatorSamplesAtHalfTheRenderRate()
    {
        using var f = new OwnerStepFixture();
        Vector3 destination = f.Owner.position + Vector3.right * 2.2f;
        f.Target(destination);
        var deltas = new System.Collections.Generic.List<float>();
        for (int frame = 0; frame < 240 && f.IsWalking; frame++)
        {
            if (frame % 2 == 0) f.AdvanceAnimator(2f / 60f);
            Vector3 before = f.Owner.position;
            float remaining = Vector3.Distance(before, destination);
            f.AdvanceRootOnly(1f / 60f);
            if (remaining > .35f) deltas.Add(Vector3.Distance(before, f.Owner.position));
        }
        Assert.That(deltas.Count, Is.GreaterThan(20));
        Assert.That(deltas.Count(value => value < .001f), Is.LessThanOrEqualTo(1),
            "A 30 Hz Animator must not make the 60 Hz owner freeze on alternate frames: " + string.Join(",", deltas.Take(16)));
        Assert.That(deltas.Max(), Is.LessThan(.05f),
            "A delayed Animator phase must not make the owner jump two frames at once.");
        Assert.That(Vector3.Distance(f.Owner.position, destination), Is.LessThan(.0001f));
    }

    [Test]
    public void RetargetReplansStrideWithoutRestartingAnimation()
    {
        using var f = new OwnerStepFixture();
        f.Target(f.Owner.position + Vector3.right * .12f);
        float smallStride = f.Animator.GetFloat("WorldWalkStride");
        for (int frame = 0; frame < 20; frame++) f.Advance(1f / 120f);
        float phase = f.LatestWalkNormalizedTime;
        float elapsed = f.Field<float>("locomotionElapsed");
        Vector3 destination = f.Owner.position + Vector3.right * 2.2f;
        f.Target(destination);
        Assert.That(f.Animator.GetFloat("WorldWalkStride"), Is.GreaterThan(smallStride));
        Assert.That(f.Field<float>("locomotionElapsed"), Is.EqualTo(elapsed));
        Assert.That(f.LatestWalkNormalizedTime, Is.EqualTo(phase));
        for (int repeat = 0; repeat < 10; repeat++) f.Target(destination);
        Assert.That(f.Field<float>("locomotionElapsed"), Is.EqualTo(elapsed));
        for (int frame = 0; frame < 600 && f.IsWalking; frame++) f.Advance(1f / 120f);
        Assert.That(f.IsWalking, Is.False);
        Assert.That(Vector3.Distance(f.Owner.position, destination), Is.LessThan(.00001f));
    }

    [Test]
    public void ShortTapCompletesOneActualWalkStepAndRepeatedTargetsDoNotRestartIt()
    {
        using var f = new OwnerStepFixture();
        Vector3 destination = f.Owner.position + Vector3.right * .12f;
        f.Target(destination);
        float step = f.Field<float>("walkingStepSeconds");
        Assert.That(step, Is.GreaterThan(.1f));
        Assert.That(f.Field<float>("targetArrivalElapsed"), Is.EqualTo(step).Within(.0001f));
        for (int frame = 0; frame < 20; frame++) f.Advance(step / 50f);
        Assert.That(f.IsWalking, Is.True, "A short tap cannot cut a swinging foot immediately to idle.");
        Assert.That(f.Owner.position.x, Is.GreaterThan(0f).And.LessThan(destination.x));
        float elapsed = f.Field<float>("locomotionElapsed");
        float normalized = f.Animator.GetCurrentAnimatorStateInfo(0).normalizedTime;
        for (int repeat = 0; repeat < 8; repeat++) f.Target(destination);
        Assert.That(f.Field<float>("locomotionElapsed"), Is.EqualTo(elapsed));
        Assert.That(f.Field<float>("targetArrivalElapsed"), Is.EqualTo(step).Within(.0001f));
        Assert.That(f.Animator.GetCurrentAnimatorStateInfo(0).normalizedTime, Is.EqualTo(normalized),
            "120 ms hold samples and unchanged snapshots must not replay standard_walk.");
        // Advance with the real Animator, not a second wall-time estimate.
        // A coarse startup frame used to end the walk at actual phase ~0.305.
        f.Advance(step * .35f);
        Assert.That(f.IsWalking, Is.True);
        for (int frame = 0; frame < 160 && f.IsWalking; frame++) f.Advance(step / 80f);
        Assert.That(f.LatestWalkNormalizedTime, Is.GreaterThanOrEqualTo(.48f),
            "The real Animator must advance through half the authored gait, including the CrossFade start.");
        float contactPhase = Mathf.Repeat(f.LatestWalkNormalizedTime, .5f);
        Assert.That(contactPhase, Is.LessThan(.015f), "Stop near the authored alternating footfall, not mid-swing.");
        Assert.That(f.LowestFootHeight, Is.LessThanOrEqualTo(f.MinimumAuthoredFootHeight + .025f),
            "At least one actual Joy foot must be within 2.5 cm of its authored planted height.");
        Assert.That(f.IsWalking, Is.False, "With no further input, the pending footfall must finish and settle.");
        Assert.That(Vector3.Distance(f.Owner.position, destination), Is.LessThan(.00001f));
        f.Target(destination);
        Assert.That(f.IsWalking, Is.False, "Holding a reached ground point must not walk in place indefinitely.");
    }

    [Test]
    public void CoarseAnimatorStartupCannotStopOnTheWallClockBeforeItsFootfall()
    {
        using var f = new OwnerStepFixture();
        f.Target(f.Owner.position + Vector3.right * .12f);
        float step = f.Field<float>("walkingStepSeconds");
        f.Advance(step * .4f);
        f.Advance(step * .59f);
        f.Advance(step * .02f);
        Assert.That(f.LatestWalkNormalizedTime, Is.LessThan(.48f), "Fixture exercises delayed CrossFade startup.");
        Assert.That(f.IsWalking, Is.True, "Wall time alone cannot end this uncompleted step.");
        for (int frame = 0; frame < 160 && f.IsWalking; frame++) f.Advance(step / 80f);
        Assert.That(f.IsWalking, Is.False);
        Assert.That(f.LatestWalkNormalizedTime, Is.GreaterThanOrEqualTo(.5f));
    }

    [Test]
    public void RetargetDuringHoldKeepsGaitPhaseAndReleaseFinishesTheLastDestination()
    {
        using var f = new OwnerStepFixture();
        f.Target(f.Owner.position + Vector3.right * .12f);
        float step = f.Field<float>("walkingStepSeconds");
        f.Advance(step * .35f);
        float elapsed = f.Field<float>("locomotionElapsed");
        Vector3 destination = f.Owner.position + Vector3.right * .65f;
        f.Target(destination);
        Assert.That(f.Field<float>("locomotionElapsed"), Is.EqualTo(elapsed),
            "Changing a held target extends the same gait instead of starting a new walk.");
        float arrival = f.Field<float>("targetArrivalElapsed");
        Assert.That(arrival / step, Is.EqualTo(Mathf.Round(arrival / step)).Within(.00001f));
        for (int frame = 0; frame < 120 && f.IsWalking; frame++) f.Advance(step / 20f);
        Assert.That(f.IsWalking, Is.False);
        Assert.That(Vector3.Distance(f.Owner.position, destination), Is.LessThan(.00001f));
    }

    [Test]
    public void WalkingFallbackWithStandardClipButNoStandardStateStillReachesItsTarget()
    {
        using var f = new OwnerStepFixture();
        f.UseWalkingFallbackController();
        Vector3 destination = f.Owner.position + Vector3.right * .4f;
        f.Target(destination);
        Assert.That(f.Field<float>("walkingStepSeconds"), Is.Zero,
            "A clip name cannot enable a clock for a missing Animator state.");
        for (int frame = 0; frame < 90 && f.IsWalking; frame++) f.Advance(1f / 60f);
        Assert.That(f.IsWalking, Is.False);
        Assert.That(Vector3.Distance(f.Owner.position, destination), Is.LessThan(.00001f));
    }

    [Test]
    public void ReplacingJoyDuringWalkingUsesTheNewAnimatorWithoutLosingTheTarget()
    {
        using var f = new OwnerStepFixture();
        Vector3 destination = f.Owner.position + Vector3.right * .7f;
        f.Target(destination);
        for (int frame = 0; frame < 15; frame++) f.Advance(1f / 60f);
        Animator previous = f.Animator;
        Vector3 position = f.Owner.position;
        f.ReplaceAvatar();
        Assert.That(f.IsWalking, Is.True, "Receiver resumes locomotion on a new VRM.");
        Assert.That(f.Owner.position, Is.EqualTo(position));
        f.Advance(1f / 60f);
        Assert.That(f.Field<Animator>("locomotionAnimator"), Is.SameAs(f.Animator).And.Not.SameAs(previous));
        for (int frame = 0; frame < 240 && f.IsWalking; frame++) f.Advance(1f / 60f);
        Assert.That(f.IsWalking, Is.False);
        Assert.That(Vector3.Distance(f.Owner.position, destination), Is.LessThan(.00001f));
    }

    [Test]
    public void RapidTapsAfterLongTravelFinishDuringThePreviousIdleCrossFade()
    {
        using var f = new OwnerStepFixture();
        float[] distances = { 2.2f, .12f, .12f, .12f };
        foreach (float distance in distances)
        {
            Vector3 destination = f.Owner.position + Vector3.right * distance;
            string trace = "before " + f.StateTrace;
            f.Target(destination);
            for (int frame = 0; frame < 360 && f.IsWalking; frame++)
            {
                f.Advance(1f / 120f);
                if (frame < 36 && frame % 6 == 0) trace += $"; f{frame} " + f.StateTrace;
            }
            Assert.That(f.IsWalking, Is.False,
                $"Tap distance={distance}, phase={f.LatestWalkNormalizedTime}, elapsed={f.Field<float>("locomotionElapsed")}, " +
                $"arrival={f.Field<float>("targetArrivalElapsed")}, origin={f.Field<float>("walkingPhaseOrigin")}. " +
                "Each tap must settle even before the outgoing idle blend completes. " + trace + "; final " + f.StateTrace);
            Assert.That(Vector3.Distance(f.Owner.position, destination), Is.LessThan(.00001f));
            // Deliberately do not advance the idle transition before the next tap.
        }
    }

    [Test]
    public void LeavingWorldCancelsPendingFootfallWithoutDelayingAvatarRelease()
    {
        using var f = new OwnerStepFixture();
        f.Target(f.Owner.position + Vector3.right * .12f);
        Assert.That(f.IsWalking, Is.True);
        f.Call("CompleteReturnToHome");
        Assert.That(f.IsWalking, Is.False);
        Assert.That(f.Field<float>("targetArrivalElapsed"), Is.Zero);
        Assert.That(f.Field<float>("walkingStepSeconds"), Is.Zero);
    }

    [TestCase(.12f,false)] [TestCase(.12f,true)]
    [TestCase(.65f,false)] [TestCase(.65f,true)]
    [TestCase(2.2f,false)] [TestCase(2.2f,true)]
    public void PersonalRoomTravelIsContinuousAndDoesNotWaitForAnAnimatorFootfall(float distance,bool pausedAnimator)
    {
        using var f=new OwnerStepFixture(personalRoom:true);
        const float delta=1f/120f,speed=1.84f;
        Vector3 destination=f.Owner.position+Vector3.right*distance;
        f.Target(destination);
        float elapsed=0;
        while(f.IsWalking && elapsed<5f)
        {
            Vector3 previous=f.Owner.position;
            float remaining=Vector3.Distance(previous,destination);
            if(!pausedAnimator)f.AdvanceAnimator(delta);
            f.AdvanceRootOnly(delta);elapsed+=delta;
            Assert.That(f.Animator.GetFloat("WorldWalkStride"),Is.EqualTo(1f).Within(.0001f),
                "A short floor target must not shrink the authored stride to fit a forced half-cycle.");
            if(remaining>speed*delta+.001f)
                Assert.That(Vector3.Distance(previous,f.Owner.position),Is.EqualTo(speed*delta).Within(.00001f),
                    "Every render tick must advance normally, independently of the Animator sampling clock.");
        }
        Assert.That(f.IsWalking,Is.False,"Arriving at the floor target cannot wait for a stalled animation phase.");
        Assert.That(elapsed,Is.LessThanOrEqualTo(distance/speed+delta*1.1f));
        Assert.That(Vector3.Distance(f.Owner.position,destination),Is.LessThan(.00001f));
    }

    [Test]
    public void PersonalRoomNearRetargetKeepsTheRunningGaitAndDoesNotQuantizeItsArrival()
    {
        using var f=new OwnerStepFixture(personalRoom:true);
        f.Target(f.Owner.position+Vector3.right*.65f);
        for(int frame=0;frame<10;frame++)f.Advance(1f/120f);
        float phase=f.LatestWalkNormalizedTime,elapsed=f.Field<float>("locomotionElapsed");
        Vector3 destination=f.Owner.position+Vector3.right*.02f;
        for(int repeat=0;repeat<12;repeat++)f.Target(destination);
        Assert.That(f.IsWalking,Is.True,"A close changed target must finish its remaining travel without stopping and restarting the gait.");
        Assert.That(f.Field<float>("locomotionElapsed"),Is.EqualTo(elapsed));
        Assert.That(f.LatestWalkNormalizedTime,Is.EqualTo(phase));
        f.AdvanceRootOnly(1f/120f);Assert.That(f.IsWalking,Is.True);
        f.AdvanceRootOnly(1f/120f);Assert.That(f.IsWalking,Is.False);
        Assert.That(Vector3.Distance(f.Owner.position,destination),Is.LessThan(.00001f));
    }

    [Test]
    public void PersonalRoomSmallRouteCornersSpendTheRemainingFrameWithoutIntermediateIdle()
    {
        using var f=new OwnerStepFixture(personalRoom:true);
        Vector3 origin=f.Owner.position;
        Vector3[] points=Enumerable.Range(1,8).Select(index=>origin+Vector3.right*(index*.03f)).ToArray();
        int waypoint=0,idleCorners=0;
        void Target()=>f.Call("ApplyRouteTarget",points[waypoint],Quaternion.identity,waypoint==points.Length-1);
        Target();
        f.Call("SetRouteContinuation",(Func<bool>)(()=>
        {
            if(!f.IsWalking)idleCorners++;
            if(++waypoint>=points.Length)return false;
            Target();return true;
        }));
        for(int frame=0;frame<20&&f.IsWalking;frame++)
        {
            Vector3 previous=f.Owner.position;
            float remaining=Vector3.Distance(previous,points.Last());
            f.AdvanceRootOnly(1f/30f);
            if(remaining>1.84f/30f+.001f)
                Assert.That(Vector3.Distance(previous,f.Owner.position),Is.EqualTo(1.84f/30f).Within(.00001f));
        }
        Assert.That(idleCorners,Is.Zero);
        Assert.That(f.IsWalking,Is.False);
        Assert.That(Vector3.Distance(f.Owner.position,points.Last()),Is.LessThan(.00001f));
    }

    private sealed class OwnerStepFixture : IDisposable
    {
        public readonly Transform Owner;
        public Animator Animator { get; private set; }
        private readonly GameObject host;
        private GameObject avatar;
        private readonly Component lease, receiver;
        private AnimatorController fallbackController;
        private AnimatorStateMachine fallbackMachine;
        public float LatestWalkNormalizedTime { get; private set; }
        public string StateTrace
        {
            get
            {
                AnimatorStateInfo current = Animator.GetCurrentAnimatorStateInfo(0);
                AnimatorStateInfo next = Animator.GetNextAnimatorStateInfo(0);
                return $"current={current.shortNameHash}/{current.normalizedTime:F3}, " +
                    $"next={next.shortNameHash}/{next.normalizedTime:F3}, transition={Animator.IsInTransition(0)}";
            }
        }
        public float MinimumAuthoredFootHeight { get; private set; }
        public float LowestFootHeight => Mathf.Min(
            Animator.GetBoneTransform(HumanBodyBones.LeftFoot).position.y,
            Animator.GetBoneTransform(HumanBodyBones.RightFoot).position.y) - avatar.transform.position.y;
        public bool IsWalking => (bool)receiver.GetType().GetProperty("IsWorldLocomotionActive").GetValue(receiver);

        public OwnerStepFixture(bool personalRoom=false)
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            host = new GameObject("OwnerStepReceiver");
            avatar = UnityEngine.Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>(
                "Assets/MaasoAvatar/Models/Default/Joy.vrm"));
            avatar.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            Animator = avatar.GetComponentInChildren<Animator>(true);
            Animator.runtimeAnimatorController = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>(
                "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller");
            Animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            Animator.applyRootMotion = false;
            Animator.Rebind();
            MinimumAuthoredFootHeight = float.PositiveInfinity;
            for (int sample = 0; sample <= 100; sample++)
            {
                Animator.Play("standard_walk", 0, sample / 100f);
                Animator.Update(0f);
                MinimumAuthoredFootHeight = Mathf.Min(MinimumAuthoredFootHeight, LowestFootHeight);
            }
            Animator.Rebind(); Animator.Play("idle_shrug", 0, 0f); Animator.Update(0f);
            receiver = host.AddComponent(Type.GetType("Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp", true));
            var serialized = new SerializedObject(receiver);
            serialized.FindProperty("avatarRoot").objectReferenceValue = avatar.transform;
            serialized.FindProperty("animator").objectReferenceValue = Animator;
            serialized.ApplyModifiedPropertiesWithoutUndo();
            Owner = new GameObject("OwnerStepLease").transform;
            lease = Owner.gameObject.AddComponent(Type.GetType("Maaso.World.WorldOwnerAvatarLease, Assembly-CSharp", true));
            Assert.That(Call(personalRoom?"BindPersonalRoom":"Bind", receiver, null, Vector3.zero, Quaternion.identity), Is.True);
        }

        public void Target(Vector3 destination) => Call("ApplyTarget", destination, Quaternion.identity, false);
        public void UseWalkingFallbackController()
        {
            fallbackController = new AnimatorController();
            fallbackMachine = new AnimatorStateMachine();
            fallbackController.layers = new[] { new AnimatorControllerLayer {
                name = "Base Layer", stateMachine = fallbackMachine, defaultWeight = 1f } };
            AnimatorState idle = fallbackMachine.AddState("idle");
            idle.motion = Array.Find(Animator.runtimeAnimatorController.animationClips, clip => clip.name == "idle_shrug");
            fallbackMachine.defaultState = idle;
            fallbackMachine.AddState("walking").motion = AssetDatabase.LoadAssetAtPath<AnimationClip>(
                "Assets/MaasoAvatar/Animations/Humanoid/Actions/standard_walk.anim");
            Animator.runtimeAnimatorController = fallbackController;
            Animator.Rebind(); Animator.Play("idle", 0, 0f); Animator.Update(0f);
        }
        public void ReplaceAvatar()
        {
            GameObject previous = avatar;
            avatar = UnityEngine.Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>(
                "Assets/MaasoAvatar/Models/Default/Joy.vrm"));
            Animator = avatar.GetComponentInChildren<Animator>(true);
            Animator.runtimeAnimatorController = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>(
                "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller");
            Animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            Animator.applyRootMotion = false;
            Animator.Rebind(); Animator.Play("idle_shrug", 0, 0f); Animator.Update(0f);
            bool previousLogPolicy = LogAssert.ignoreFailingMessages;
            try
            {
                // UniVRM's production binding instantiates runtime materials;
                // Unity reports this when exercised deliberately in EditMode.
                LogAssert.ignoreFailingMessages = true;
                receiver.GetType().GetMethod("BindAvatarRoot", BindingFlags.Instance | BindingFlags.NonPublic)
                    .Invoke(receiver, new object[] { avatar.transform });
            }
            finally { LogAssert.ignoreFailingMessages = previousLogPolicy; }
            UnityEngine.Object.DestroyImmediate(previous);
        }
        public void Advance(float seconds)
        {
            AdvanceAnimator(seconds);
            AdvanceRootOnly(seconds);
        }
        public void AdvanceAnimator(float seconds)
        {
            Animator.Update(seconds);
            AnimatorStateInfo current = Animator.GetCurrentAnimatorStateInfo(0);
            AnimatorStateInfo next = Animator.GetNextAnimatorStateInfo(0);
            if (current.IsName("standard_walk")) LatestWalkNormalizedTime = current.normalizedTime;
            else if (Animator.IsInTransition(0) && next.IsName("standard_walk")) LatestWalkNormalizedTime = next.normalizedTime;
        }
        public void AdvanceRootOnly(float seconds)
        {
            Call("AdvanceLocomotion", seconds);
        }
        public T Field<T>(string name) => (T)lease.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic).GetValue(lease);
        public object Call(string name, params object[] arguments)
        {
            try { return lease.GetType().GetMethod(name, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic).Invoke(lease, arguments); }
            catch (TargetInvocationException error) { throw error.InnerException ?? error; }
        }
        public void Dispose()
        {
            UnityEngine.Object.DestroyImmediate(Owner.gameObject);
            UnityEngine.Object.DestroyImmediate(host);
            if (avatar != null) UnityEngine.Object.DestroyImmediate(avatar);
            if (fallbackMachine != null)
            {
                foreach (ChildAnimatorState state in fallbackMachine.states)
                    UnityEngine.Object.DestroyImmediate(state.state);
                UnityEngine.Object.DestroyImmediate(fallbackMachine);
            }
            if (fallbackController != null) UnityEngine.Object.DestroyImmediate(fallbackController);
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        }
    }

    [Test]
    public void NearOrInvalidTargetKeepsFallbackFacing()
    {
        Assert.That(Subject, Is.Not.Null);
        MethodInfo method = Subject.GetMethod(
            "ResolveFacing",
            BindingFlags.Public | BindingFlags.Static);
        Quaternion fallback = Quaternion.Euler(0f, 37f, 0f);

        Assert.That(
            (Quaternion)method.Invoke(
                null,
                new object[] { Vector3.zero, Vector3.zero, fallback }),
            Is.EqualTo(fallback));
        Assert.That(
            (Quaternion)method.Invoke(
                null,
                new object[]
                {
                    Vector3.zero,
                    new Vector3(float.NaN, 0f, 1f),
                    fallback,
                }),
            Is.EqualTo(fallback));
    }
}

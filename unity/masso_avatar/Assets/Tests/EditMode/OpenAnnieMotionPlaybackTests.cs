using System;
using System.Reflection;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.Animations;
using UnityEditor.SceneManagement;
using UnityEngine;
using Object = UnityEngine.Object;

public sealed class OpenAnnieMotionPlaybackTests
{
    private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
    private static Type A(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    private static object Call(object target, string method, params object[] args) => target.GetType()
        .GetMethod(method, BindingFlags.Public | Private).Invoke(target, args);

    [Test]
    public void UpperBodyEntersFadesAndReleasesWithoutMovingActor()
    {
        using var f = new Fixture();
        Vector3 position = f.Avatar.transform.position;
        Quaternion rotation = f.Avatar.transform.rotation;
        Assert.That(Call(f.Player, "TryPlay", f.Animator, "annie_g_offer_r", 10f, false, 0f), Is.True);
        Call(f.Player, "Advance", f.Animator, 10.3f, false);
        Assert.That(f.Animator.GetLayerWeight(f.Layer), Is.EqualTo(1f));
        f.Animator.Update(.4f);
        Assert.That(Call(f.Player, "Advance", f.Animator, 11.85f, false), Is.False);
        Assert.That(f.Animator.GetLayerWeight(f.Layer), Is.InRange(.01f, .5f));
        Assert.That(Call(f.Player, "Advance", f.Animator, 12f, false), Is.True);
        Assert.That(f.Animator.GetLayerWeight(f.Layer), Is.Zero);
        Assert.That(f.Avatar.transform.position, Is.EqualTo(position));
        Assert.That(Quaternion.Angle(f.Avatar.transform.rotation, rotation), Is.LessThan(.001f));
    }

    [Test]
    public void LoopHasBoundedLifetimeAndOwnershipLossReleasesImmediately()
    {
        using var f = new Fixture();
        Assert.That(Call(f.Player, "TryPlay", f.Animator, "annie_talk_calm_1", 0f, false, 2f), Is.True);
        Call(f.Player, "Advance", f.Animator, .3f, false);
        Assert.That(f.Animator.GetLayerWeight(f.Layer), Is.EqualTo(1f));
        Assert.That(Call(f.Player, "Advance", f.Animator, .4f, true), Is.True);
        Assert.That(f.Animator.GetLayerWeight(f.Layer), Is.Zero);
        Assert.That(Call(f.Player, "TryPlay", f.Animator, "annie_talk_calm_1", 10f, false, 2f), Is.True);
        Assert.That(Call(f.Player, "Advance", f.Animator, 12.1f, false), Is.True);
    }

    [Test]
    public void BentArmIdleInterludeEndsAfterOneAuthoredCycle()
    {
        using var f = new Fixture();
        Assert.That(Call(f.Player, "TryPlayAtPhase", f.Animator, "annie_idle_c", 10f, false, 0f, 0f), Is.True);
        Assert.That(Call(f.Player, "Advance", f.Animator, 15.99f, false), Is.False);
        Assert.That(Call(f.Player, "Advance", f.Animator, 16f, false), Is.True);
        Assert.That(Call(f.Player, "TryPlayBaseIdle", f.Animator, "idle_shrug", 16f, false, 30f), Is.True);
        f.Animator.Update(.3f);
        Assert.That(f.Animator.GetCurrentAnimatorStateInfo(0).IsName("Base Layer.idle_shrug"), Is.True);
        Assert.That(Call(f.Player, "Advance", f.Animator, 16.3f, true), Is.True,
            "Task and locomotion ownership still release the ambient base immediately.");
    }

    [Test]
    public void NativeBaseLeaseRenewalPreservesActualAnimatorPhaseAndBlocksTaskTakeover()
    {
        using var f = new Fixture();
        f.Animator.Play("idle_shrug", 0, .37f); f.Animator.Update(0f);
        float phase = f.Animator.GetCurrentAnimatorStateInfo(0).normalizedTime;
        Assert.That(Call(f.Player, "TryPlayBaseIdle", f.Animator, "idle_shrug", 10f, false, 30f), Is.True);
        f.Animator.Update(0f);
        Assert.That(f.Animator.IsInTransition(0), Is.False);
        Assert.That(f.Animator.GetCurrentAnimatorStateInfo(0).normalizedTime, Is.EqualTo(phase).Within(.0001f));
        f.Animator.Update(1f);
        phase = f.Animator.GetCurrentAnimatorStateInfo(0).normalizedTime;
        Assert.That(Call(f.Player, "Advance", f.Animator, 40f, false), Is.True);
        Assert.That(Call(f.Player, "TryPlayBaseIdle", f.Animator, "idle_shrug", 40f, false, 30f), Is.True);
        f.Animator.Update(0f);
        Assert.That(f.Animator.IsInTransition(0), Is.False);
        Assert.That(f.Animator.GetCurrentAnimatorStateInfo(0).normalizedTime, Is.EqualTo(phase).Within(.0001f));
        Assert.That(Call(f.Player, "Advance", f.Animator, 40.1f, true), Is.True);
        Assert.That(Call(f.Player, "TryPlayBaseIdle", f.Animator, "idle_shrug", 40.2f, true, 30f), Is.False);
    }

    [Test]
    public void BlockedUnknownAndModelReplacementDoNotStealPose()
    {
        using var f = new Fixture();
        Assert.That(Call(f.Player, "TryPlay", f.Animator, "annie_wave", 0f, true, 0f), Is.False);
        Assert.That(Call(f.Player, "TryPlay", f.Animator, "annie_missing", 0f, false, 0f), Is.False);
        Assert.That(f.Animator.GetLayerWeight(f.Layer), Is.Zero);
        Assert.That(Call(f.Player, "TryPlay", f.Animator, "annie_g_offer_r", 0f, false, 0f), Is.True);
        Call(f.Player, "Advance", f.Animator, .3f, false);
        Assert.That(Call(f.Player, "Advance", null, .4f, false), Is.True);
        Assert.That(f.Animator.GetLayerWeight(f.Layer), Is.Zero);
    }

    [Test]
    public void PrimitivePlaybackCanReachImportedMotionAndReset()
    {
        using var f = new Fixture();
        var host = new GameObject("Annie receiver test");
        try
        {
            Component receiver = host.AddComponent(A("UnityAvatarCommandReceiver"));
            receiver.GetType().GetField("avatarRoot", Private).SetValue(receiver, f.Avatar.transform);
            receiver.GetType().GetField("animator", Private).SetValue(receiver, f.Animator);
            Call(receiver.GetType().GetField("localVisibility", Private).GetValue(receiver), "SetVisible", true);
            Call(receiver, "ApplyPrimitive", "wave", .75f);
            object player = receiver.GetType().GetField("annieMotion", Private).GetValue(receiver);
            Assert.That(player.GetType().GetProperty("ActiveId").GetValue(player), Is.EqualTo("annie_wave"));
            float hold = (float)receiver.GetType().GetField("actionPoseHoldUntil", Private).GetValue(receiver);
            Assert.That(hold - Time.realtimeSinceStartup, Is.GreaterThan(2.3f));
            Call(receiver, "ResetAvatarArbiterBodyGesture");
            Assert.That(player.GetType().GetProperty("ActiveId").GetValue(player), Is.Null);
            Call(receiver, "ApplyPrimitive", "explain", .75f);
            Assert.That(player.GetType().GetProperty("ActiveId").GetValue(player), Is.EqualTo("annie_g_roll_both"));
            Call(receiver, "OnDisable");
            Assert.That(f.Animator.GetLayerWeight(f.Layer), Is.Zero);
        }
        finally { Object.DestroyImmediate(host); }
    }

    [Test]
    public void FullBodyToUpperBodyReplacementRestoresBaseIdle()
    {
        using var f = new Fixture();
        Assert.That(Call(f.Player, "TryPlay", f.Animator, "annie_dance", 0f, false, 0f), Is.True);
        f.Animator.Update(.5f);
        Assert.That(Call(f.Player, "TryPlay", f.Animator, "annie_g_offer_r", .5f, false, 0f), Is.True);
        f.Animator.Update(.3f);
        Assert.That(f.Animator.GetCurrentAnimatorStateInfo(0).IsName("Base Layer.idle_shrug"), Is.True,
            "The replaced dance must not continue animating the legs below an upper-body action.");
    }

    [TestCase(1200)]
    [TestCase(4000)]
    public void RetiringBackgroundClipKeepsNewerTemporaryTurnDeadline(int durationMs)
    {
        using var f = new Fixture();
        var host = new GameObject("Annie newer turn test");
        try
        {
            Component receiver = host.AddComponent(A("UnityAvatarCommandReceiver"));
            receiver.GetType().GetField("avatarRoot", Private).SetValue(receiver, f.Avatar.transform);
            receiver.GetType().GetField("animator", Private).SetValue(receiver, f.Animator);
            Call(receiver.GetType().GetField("localVisibility", Private).GetValue(receiver), "SetVisible", true);
            Call(receiver, "ApplyPrimitive", "wave", .75f);
            Type commandType = receiver.GetType().GetNestedType("MotionCommand", BindingFlags.NonPublic);
            object command = JsonUtility.FromJson("{\"type\":\"turn_left\",\"options\":{\"durationMs\":" + durationMs + "}}", commandType);
            Call(receiver, "PlayMotion", command);
            float deadline = (float)receiver.GetType().GetField("actionPoseHoldUntil", Private).GetValue(receiver);
            Assert.That(deadline - Time.realtimeSinceStartup, Is.EqualTo(durationMs / 1000f).Within(.08f));
            Call(receiver, "LateUpdate");
            Assert.That((float)receiver.GetType().GetField("actionPoseHoldUntil", Private).GetValue(receiver), Is.EqualTo(deadline));
            Assert.That((bool)receiver.GetType().GetField("temporaryTurnReturning", Private).GetValue(receiver), Is.False);
        }
        finally { Object.DestroyImmediate(host); }
    }

    [Test]
    public void AvatarWithOwnControllerFallsBackToItsExistingWave()
    {
        using var f = new Fixture();
        var controller = new AnimatorController();
        controller.AddLayer("Base Layer");
        var idle = controller.layers[0].stateMachine.AddState("custom_idle");
        idle.motion = AssetDatabase.LoadAssetAtPath<AnimationClip>("Assets/MaasoAvatar/Animations/Humanoid/Actions/idle_shrug.anim");
        controller.layers[0].stateMachine.defaultState = idle;
        var state = controller.layers[0].stateMachine.AddState("wave");
        state.motion = AssetDatabase.LoadAssetAtPath<AnimationClip>("Assets/MaasoAvatar/Animations/Humanoid/Actions/wave.anim");
        f.Animator.runtimeAnimatorController = controller;
        f.Animator.Rebind(); f.Animator.Update(0f);
        var host = new GameObject("Annie custom controller test");
        try
        {
            Component receiver = host.AddComponent(A("UnityAvatarCommandReceiver"));
            receiver.GetType().GetField("avatarRoot", Private).SetValue(receiver, f.Avatar.transform);
            receiver.GetType().GetField("animator", Private).SetValue(receiver, f.Animator);
            Call(receiver.GetType().GetField("localVisibility", Private).GetValue(receiver), "SetVisible", true);
            Type commandType = receiver.GetType().GetNestedType("AnimationClipCommand", BindingFlags.NonPublic);
            Call(receiver, "PlayAnimationClip", JsonUtility.FromJson("{\"id\":\"annie_wave\"}", commandType));
            f.Animator.Update(.3f);
            Assert.That(f.Animator.GetCurrentAnimatorStateInfo(0).IsName("Base Layer.wave") ||
                (f.Animator.IsInTransition(0) && f.Animator.GetNextAnimatorStateInfo(0).IsName("Base Layer.wave")), Is.True,
                "The custom controller's original wave can be active or in its authored transition.");
        }
        finally { Object.DestroyImmediate(host); Object.DestroyImmediate(controller); }
    }

    [TestCase("worldLocomotionActive")]
    [TestCase("avatarLeasedToWorld")]
    [TestCase("bodyPoseTransitionActive")]
    [TestCase("hidden")]
    public void TaskAndNavigationOwnershipRejectsNewMotion(string field)
    {
        using var f = new Fixture();
        var host = new GameObject("Busy Annie receiver test");
        try
        {
            Component receiver = host.AddComponent(A("UnityAvatarCommandReceiver"));
            receiver.GetType().GetField("avatarRoot", Private).SetValue(receiver, f.Avatar.transform);
            receiver.GetType().GetField("animator", Private).SetValue(receiver, f.Animator);
            Call(receiver.GetType().GetField("localVisibility", Private).GetValue(receiver), "SetVisible", field != "hidden");
            if (field != "hidden") receiver.GetType().GetField(field, Private).SetValue(receiver, true);
            Assert.That(Call(receiver, "TryPlayPrimitiveAnimation", "wave"), Is.True,
                "A blocked imported semantic action is consumed without falling back to a conflicting pose.");
            object player = receiver.GetType().GetField("annieMotion", Private).GetValue(receiver);
            Assert.That(player.GetType().GetProperty("ActiveId").GetValue(player), Is.Null);
            Assert.That(f.Animator.GetLayerWeight(f.Layer), Is.Zero);
        }
        finally { Object.DestroyImmediate(host); }
    }

    private sealed class Fixture : IDisposable
    {
        public readonly GameObject Avatar;
        public readonly Animator Animator;
        public readonly object Player;
        public readonly int Layer;
        public Fixture()
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            Avatar = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm"));
            Avatar.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            Animator = Avatar.GetComponentInChildren<Animator>(true);
            Animator.runtimeAnimatorController = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>(
                "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller");
            Animator.applyRootMotion = false;
            Animator.Rebind(); Animator.Update(0f);
            Layer = Animator.GetLayerIndex("Annie Upper Body");
            Assert.That(Layer, Is.GreaterThan(0));
            Player = Activator.CreateInstance(A("OpenAnnieMotionPlayback"));
        }
        public void Dispose()
        {
            Object.DestroyImmediate(Avatar);
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        }
    }
}

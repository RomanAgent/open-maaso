using System;
using System.Collections.Generic;
using System.Linq;
using NUnit.Framework;
using UniVRM10;
using UnityEditor;
using UnityEditor.Animations;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.TestTools;
using Object = UnityEngine.Object;

/// <summary>Actual shared-controller retarget regressions; no synthetic rig or replacement poses.</summary>
public sealed class AvatarIdleTransitionRegressionTests
{
    private const string ControllerPath = "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller";

    [Test]
    public void OfficialControllerUsesAuthoredForwardKinematicsWithoutImplicitFootGoalSolving()
    {
        AnimatorController controller = AssetDatabase.LoadAssetAtPath<AnimatorController>(ControllerPath);
        Assert.That(controller, Is.Not.Null);
        var states = controller.layers.SelectMany(layer => AllStates(layer.stateMachine)).ToArray();
        Assert.That(states.Any(state => state.name == "idle_shrug"), Is.True);
        Assert.That(states.Any(state => state.name == "standard_walk"), Is.True);
        Assert.That(states.Any(state => state.name == "annie_idle_c"), Is.True);
        foreach (AnimatorState state in states)
            Assert.That(state.iKOnFeet, Is.False, state.name + ": mixing imported goal-solving with goal-free Annie poses folds legs during crossfades.");
    }

    [TestCase("annie_idle_c")]
    [TestCase("annie_listen_b")]
    [TestCase("annie_fidget_hips")]
    public void ActualModelKeepsItsFeetAndLegLengthsDuringBothSidesOfAnIdleCrossfade(string destination)
    {
        using var f = new Fixture();
        for (int frame = 0; frame < 60; frame++) f.Step();
        Vector3 hips = f.Hips.position;
        float leftY = f.LeftFoot.position.y, rightY = f.RightFoot.position.y;
        float[] lengths = f.LegLengths();
        float maximumRise = 0f, maximumHipTravel = 0f;
        for (int frame = 0; frame < 300; frame++)
        {
            if (frame == 0) f.Animator.CrossFadeInFixedTime("Base Layer." + destination, .12f, 0, 0f);
            if (frame == 150) f.Animator.CrossFadeInFixedTime("Base Layer.idle_shrug", .2f, 0, 0f);
            f.Step();
            float rise = Mathf.Max(f.LeftFoot.position.y - leftY, f.RightFoot.position.y - rightY);
            float hipTravel = Vector3.Distance(f.Hips.position, hips);
            maximumRise = Mathf.Max(maximumRise, rise);
            maximumHipTravel = Mathf.Max(maximumHipTravel, hipTravel);
            string label = "Joy" + "/" + destination + "/frame" + frame;
            Assert.That(float.IsNaN(rise) || float.IsInfinity(rise), Is.False, label);
            Assert.That(rise, Is.LessThan(.04f), label + ": standing ankles must not snap up toward the hips.");
            Assert.That(hipTravel, Is.LessThan(.1f), label + ": source standing motions must remain near their settled baseline.");
            float[] actual = f.LegLengths();
            for (int segment = 0; segment < actual.Length; segment++)
                Assert.That(Mathf.Abs(actual[segment] - lengths[segment]), Is.LessThan(.001f), label + "/leg segment " + segment);
        }
        TestContext.WriteLine("Joy" + "/" + destination +
            ": max ankle rise=" + maximumRise + "m; max hip travel=" + maximumHipTravel + "m");
        Assert.That(f.Animator.GetCurrentAnimatorStateInfo(0).IsName("idle_shrug"), Is.True,
            "The test must exercise the actual return to the legacy idle, not stop after entering Annie.");
        Assert.That(f.Animator.IsInTransition(0), Is.False);
    }

    private static IEnumerable<AnimatorState> AllStates(AnimatorStateMachine machine)
    {
        foreach (ChildAnimatorState state in machine.states) yield return state.state;
        foreach (ChildAnimatorStateMachine child in machine.stateMachines)
            foreach (AnimatorState state in AllStates(child.stateMachine)) yield return state;
    }

    private sealed class Fixture : IDisposable
    {
        public readonly GameObject Root;
        public readonly Animator Animator;
        public readonly Vrm10Instance Vrm;
        public readonly Transform Hips, LeftUpper, LeftKnee, LeftFoot, RightUpper, RightKnee, RightFoot;
        private readonly Dictionary<Renderer, Material[]> originalMaterials;
        private readonly Vrm10Runtime vrmRuntime;

        public Fixture()
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            Root = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm"));
            Root.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            originalMaterials = Root.GetComponentsInChildren<Renderer>(true)
                .ToDictionary(renderer => renderer, renderer => renderer.sharedMaterials);
            Animator = Root.GetComponentInChildren<Animator>(true);
            Vrm = Root.GetComponentInChildren<Vrm10Instance>(true);
            if (Vrm != null)
            {
                Vrm.enabled = false;
                int slots = originalMaterials.Values.Sum(materials => materials.Count(material => material != null));
                Assert.That(slots, Is.EqualTo(17), "Reviewed Joy runtime material inventory changed.");
                for (int slot = 0; slot < slots; slot++) LogAssert.Expect(LogType.Error,
                    "Instantiating material due to calling renderer.material during edit mode. This will leak materials into the scene. You most likely want to use renderer.sharedMaterial instead.");
                vrmRuntime = Vrm.Runtime;
                // Preserve the actual imported Joy runtime mode; raw humanoid bones
                // remain the observable output whether a normalized control rig exists.
            }
            Animator.runtimeAnimatorController = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>(ControllerPath);
            Animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            Animator.applyRootMotion = false;
            Animator.Rebind(); Animator.Play("Base Layer.idle_shrug", 0, 0f);
            Animator.Update(0f); vrmRuntime?.Process();
            Transform Bone(HumanBodyBones id) => Vrm != null ? Vrm.Humanoid.GetBoneTransform(id) : Animator.GetBoneTransform(id);
            Hips = Bone(HumanBodyBones.Hips);
            LeftUpper = Bone(HumanBodyBones.LeftUpperLeg); LeftKnee = Bone(HumanBodyBones.LeftLowerLeg); LeftFoot = Bone(HumanBodyBones.LeftFoot);
            RightUpper = Bone(HumanBodyBones.RightUpperLeg); RightKnee = Bone(HumanBodyBones.RightLowerLeg); RightFoot = Bone(HumanBodyBones.RightFoot);
            foreach (Transform bone in new[] { Hips, LeftUpper, LeftKnee, LeftFoot, RightUpper, RightKnee, RightFoot }) Assert.That(bone, Is.Not.Null);
        }

        public void Step() { Animator.Update(1f / 60f); vrmRuntime?.Process(); }
        public float[] LegLengths() => new[] { Vector3.Distance(LeftUpper.position, LeftKnee.position),
            Vector3.Distance(LeftKnee.position, LeftFoot.position), Vector3.Distance(RightUpper.position, RightKnee.position),
            Vector3.Distance(RightKnee.position, RightFoot.position) };

        public void Dispose()
        {
            var borrowed = new HashSet<Material>(originalMaterials.Values.SelectMany(materials => materials));
            Material[] clones = originalMaterials.Keys.Where(renderer => renderer != null).SelectMany(renderer => renderer.sharedMaterials)
                .Where(material => material != null && !borrowed.Contains(material) && !AssetDatabase.Contains(material)).Distinct().ToArray();
            foreach (var pair in originalMaterials) if (pair.Key != null) pair.Key.sharedMaterials = pair.Value;
            foreach (Material material in clones) Object.DestroyImmediate(material);
            if (vrmRuntime?.ControlRig != null)
            {
                Object.DestroyImmediate(vrmRuntime.ControlRig.ControlRigAnimator.avatar);
                Transform controls = Vrm.transform.Find("Runtime Control Rig");
                if (controls != null) Object.DestroyImmediate(controls.gameObject);
            }
            Object.DestroyImmediate(Root);
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        }
    }
}

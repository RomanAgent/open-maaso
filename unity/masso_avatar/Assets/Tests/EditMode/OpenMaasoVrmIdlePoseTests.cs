using System;
using System.Linq;
using System.Reflection;
using System.Text.RegularExpressions;
using NUnit.Framework;
using UniVRM10;
using UnityEditor;
using UnityEngine;
using UnityEngine.TestTools;
using Object = UnityEngine.Object;

public sealed class OpenMaasoVrmIdlePoseTests
{
    private const string ModelPath = "Assets/MaasoAvatar/Models/Default/OpenMaaso.vrm";
    private GameObject model;
    private Animator animator;
    private Vrm10Instance vrm;
    private HumanPose imported;

    [SetUp]
    public void SetUp()
    {
        model = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>(ModelPath));
        animator = model.GetComponentInChildren<Animator>();
        animator.applyRootMotion = false;
        vrm = model.GetComponentInChildren<Vrm10Instance>();
        imported = new HumanPose();
        using (var handler = new HumanPoseHandler(animator.avatar, animator.transform)) handler.GetHumanPose(ref imported);
        Type builder = Type.GetType("Maaso.Avatar.Editor.MaasoDefaultAvatarSceneBuilder, Assembly-CSharp-Editor", true);
        animator.runtimeAnimatorController = (RuntimeAnimatorController)builder.GetMethod("EnsureOfflineController", BindingFlags.Static | BindingFlags.NonPublic)
            .Invoke(null, new object[] { animator });
        animator.Rebind();
    }

    [TearDown]
    public void TearDown() => Object.DestroyImmediate(model);

    [Test]
    public void RealVrmIdleKeepsHandsSeparateElbowsExtendedAndKneesStableThroughoutTheLoop()
    {
        // UniVRM clones renderer material slots when initializing an Editor
        // prefab runtime. Expect only that documented Editor-only diagnostic.
        int materialSlots = vrm.GetComponentsInChildren<Renderer>()
            .Where(renderer => renderer is SkinnedMeshRenderer || renderer is MeshRenderer)
            .Sum(renderer => renderer.sharedMaterials.Length);
        for (int index = 0; index < materialSlots; index++)
            LogAssert.Expect(LogType.Error, new Regex("Instantiating material due to calling renderer\\.material"));
        vrm.Runtime.Process();
        Vector3 rootPosition = model.transform.position;
        Quaternion rootRotation = model.transform.rotation;
        foreach (float sample in new[] { 0f, .5f, 2f, 3.99f, 4f, 8f })
        {
            animator.Play("Idle", 0, sample / 4f); animator.Update(0f); vrm.Runtime.Process();
            Vector3 Bone(HumanBodyBones bone) => animator.GetBoneTransform(bone).position;
            float shoulderWidth = Vector3.Distance(Bone(HumanBodyBones.LeftUpperArm), Bone(HumanBodyBones.RightUpperArm));
            Assert.That(Vector3.Distance(Bone(HumanBodyBones.LeftHand), Bone(HumanBodyBones.RightHand)), Is.GreaterThan(shoulderWidth * 1.3f), "Hands must not collapse into the abdomen/each other.");
            foreach (bool left in new[] { true, false })
            {
                Vector3 upper = Bone(left ? HumanBodyBones.LeftUpperArm : HumanBodyBones.RightUpperArm);
                Vector3 elbow = Bone(left ? HumanBodyBones.LeftLowerArm : HumanBodyBones.RightLowerArm);
                Vector3 hand = Bone(left ? HumanBodyBones.LeftHand : HumanBodyBones.RightHand);
                Assert.That(Vector3.Angle(upper - elbow, hand - elbow), Is.GreaterThan(165f), "The neutral clip must not recreate the old 100-degree default elbow.");
                Assert.That(Vector3.Dot(hand - Bone(HumanBodyBones.Hips), model.transform.forward), Is.GreaterThan(-.06f), "Neutral hands must not disappear behind the hip/garment plane.");
                Vector3 thigh = Bone(left ? HumanBodyBones.LeftUpperLeg : HumanBodyBones.RightUpperLeg);
                Vector3 knee = Bone(left ? HumanBodyBones.LeftLowerLeg : HumanBodyBones.RightLowerLeg);
                Vector3 foot = Bone(left ? HumanBodyBones.LeftFoot : HumanBodyBones.RightFoot);
                Assert.That(Vector3.Angle(thigh - knee, foot - knee), Is.GreaterThan(165f), "Imported straight-leg alignment must not fall back to Unity's zero-muscle knee pose.");
            }
            Assert.That(model.transform.position, Is.EqualTo(rootPosition));
            Assert.That(model.transform.rotation, Is.EqualTo(rootRotation));
        }
    }

    [Test]
    public void FreshGenerationPreservesImportedLimbAndFingerMusclesWithoutTakingOverSpeechOrEyes()
    {
        var clip = AssetDatabase.LoadAssetAtPath<AnimationClip>("Assets/MaasoAvatar/Animations/Humanoid/OfflineIdle.anim");
        for (int index = 0; index < HumanTrait.MuscleCount; index++)
        {
            string name = HumanTrait.MuscleName[index];
            int bone = HumanTrait.BoneFromMuscle(index);
            var curve = AnimationUtility.GetEditorCurve(clip, EditorCurveBinding.FloatCurve("", typeof(Animator), name));
            if (bone == (int)HumanBodyBones.LeftEye || bone == (int)HumanBodyBones.RightEye || bone == (int)HumanBodyBones.Jaw)
            {
                Assert.That(curve, Is.Null, "Idle must not acquire expression/TTS-owned channels: " + name);
                continue;
            }
            Assert.That(curve, Is.Not.Null, "Missing model-specific muscle baseline: " + name);
            float expected = name is "Left Arm Down-Up" or "Right Arm Down-Up" ? -.65f :
                name is "Left Arm Front-Back" or "Right Arm Front-Back" ? .15f : Mathf.Clamp(imported.muscles[index], -1f, 1f);
            Assert.That(curve.Evaluate(0f), Is.EqualTo(expected).Within(.0001f), name);
            Assert.That(curve.Evaluate(4f), Is.EqualTo(expected).Within(.0001f), name);
        }
    }
}

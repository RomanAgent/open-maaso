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

public sealed class AvatarMicroMotionCollisionRegressionTests
{
    private static readonly Type Micro = Type.GetType("Maaso.Avatar.AvatarConversationalMicroMotion, Assembly-CSharp", true);
    private static readonly Type Guard = Type.GetType("Maaso.Avatar.AvatarFreeGestureCollisionGuard, Assembly-CSharp", true);
    private static readonly Type Ik = Type.GetType("Maaso.Avatar.AvatarArmIk, Assembly-CSharp", true);
    private static object Call(object value, string method, params object[] args) => value.GetType().GetMethod(method).Invoke(value, args);
    private static T Read<T>(object value, string property) => (T)value.GetType().GetProperty(property).GetValue(value);

    [Test]
    public void RealListeningEdgesProduceSmallBackchannelsAndRestoreWithoutRootLegFingerOrFaceWrites()
    {
        using var f = new Fixture();
        object micro = Activator.CreateInstance(Micro); Call(micro, "Bind", f.Animator);
        Assert.That(Read<int>(micro, "BoneCount"), Is.GreaterThanOrEqualTo(3));
        Call(micro, "SetPhase", "listening", 0f);
        bool observed = false; float maximumHeadStep = 0f;
        for (int frame = 0; frame < 180; frame++)
        {
            Call(micro, "RestoreBeforeAnimation"); f.Step();
            var before = f.LocalPoses(); var mouth = f.Morphs();
            Quaternion head = f.Bone(HumanBodyBones.Head).rotation;
            Call(micro, "Apply", frame / 60f, true);
            observed |= Read<bool>(micro, "BackchannelActive");
            maximumHeadStep = Mathf.Max(maximumHeadStep, Quaternion.Angle(head, f.Bone(HumanBodyBones.Head).rotation));
            foreach (var pair in before)
                if (f.Protected(pair.Key)) AssertLocalPose(pair.Key, pair.Value, "micro-motion must preserve protected " + pair.Key.name);
            AssertMorphs(f, mouth);
            Call(micro, "RestoreBeforeAnimation");
            foreach (var pair in before) AssertLocalPose(pair.Key, pair.Value, "restore " + pair.Key.name);
        }
        Assert.That(observed, Is.True, "A real listening transition must create a visible, bounded backchannel.");
        Assert.That(maximumHeadStep, Is.InRange(.2f, 4.5f));
        Call(micro, "SetPhase", "speaking", 3f); Call(micro, "NotifyPause", 3.1f); Call(micro, "Apply", 3.1f, true);
        Assert.That(Read<bool>(micro, "BackchannelActive"), Is.False, "An output speech pause cannot fabricate listening agreement.");
        Call(micro, "Apply", 3.2f, false);
        Assert.That(Read<bool>(micro, "HasOwnedWrites"), Is.False, "Task/mute/background gates must release immediately.");
        Call(micro, "Reset");
    }

    [TestCase(.75f, 37f)]
    [TestCase(1.4f, -61f)]
    public void ActualSkinRestProbesCalibrateAndFollowTranslatedRotatedScaledRoots(float scale, float yaw)
    {
        using var f = new Fixture();
        object guard = Activator.CreateInstance(Guard);
        Assert.That(Call(guard, "Bind", f.Root.transform, f.Animator), Is.True, "The actual model must supply readable calibrated body/head/arm/palm probes: " + Read<string>(guard, "BindingDiagnostic"));
        Assert.That(Read<int>(guard, "CalibrationVertexCount"), Is.GreaterThan(100));
        Vector3 center = Read<Vector3>(guard, "HeadCenter"), bodyA = Read<Vector3>(guard, "TorsoStart"), bodyB = Read<Vector3>(guard, "TorsoEnd");
        float bodyRadius = Read<float>(guard, "BodyRadius"), headRadius = Read<float>(guard, "HeadRadius");
        Assert.That(bodyRadius, Is.GreaterThan(.05f)); Assert.That(headRadius, Is.GreaterThan(.05f));
        Vector3 position = new(2.1f, .3f, -1.7f); Quaternion rotation = Quaternion.Euler(0f, yaw, 0f);
        f.Root.transform.SetPositionAndRotation(position, rotation); f.Root.transform.localScale = Vector3.one * scale;
        Assert.That(Vector3.Distance(Read<Vector3>(guard, "HeadCenter"), position + rotation * (center * scale)), Is.LessThan(.0001f));
        Assert.That(Vector3.Distance(Read<Vector3>(guard, "TorsoStart"), position + rotation * (bodyA * scale)), Is.LessThan(.0001f));
        Assert.That(Read<float>(guard, "BodyRadius"), Is.EqualTo(bodyRadius * scale).Within(.0001f));
        Assert.That(Read<float>(guard, "HeadRadius"), Is.EqualTo(headRadius * scale).Within(.0001f));
        Vector3 point = position + rotation * ((bodyA + bodyB) * (.5f * scale));
        float independent = Mathf.Min(DistanceToSegment(point, Read<Vector3>(guard, "TorsoStart"), Read<Vector3>(guard, "TorsoEnd")) - Read<float>(guard, "BodyRadius"),
            Vector3.Distance(point, Read<Vector3>(guard, "HeadCenter")) - Read<float>(guard, "HeadRadius"));
        float measured = (float)Call(guard, "PointClearance", point, 0f);
        Assert.That(measured, Is.LessThan(independent));
        Assert.That(independent - measured, Is.LessThan(.01f * scale), "Only a small body-scaled clearance margin is added.");
    }

    [TestCase(false)]
    [TestCase(true)]
    public void DeliberateActualArmTorsoOrHeadOverlapGetsBoundedCorrectionWithoutWristFingerOrLegDamage(bool atHead)
    {
        using var f = new Fixture();
        object guard = Activator.CreateInstance(Guard);
        Assert.That(Call(guard, "Bind", f.Root.transform, f.Animator), Is.True, Read<string>(guard, "BindingDiagnostic"));
        Transform upper = f.Bone(HumanBodyBones.LeftUpperArm), lower = f.Bone(HumanBodyBones.LeftLowerArm), hand = f.Bone(HumanBodyBones.LeftHand);
        Vector3 target = atHead ? Read<Vector3>(guard, "HeadCenter") - f.Root.transform.up * .08f :
            Vector3.Lerp(Read<Vector3>(guard, "TorsoStart"), Read<Vector3>(guard, "TorsoEnd"), .7f);
        bool placed = (bool)Ik.GetMethod("Apply").Invoke(null, new object[] { upper, lower, hand, target, -f.Root.transform.right, 180f });
        Assert.That(placed, Is.True, "Setup uses actual two-bone lengths, never stretching or relocating a joint directly.");
        float before = (float)Call(guard, "ArmClearance", true);
        Assert.That(before, Is.LessThan(-.01f), "The real fixture must start with a genuine sampled overlap.");
        var pose = f.LocalPoses(); var morphs = f.Morphs(); Quaternion wrist = hand.rotation;
        float a = Vector3.Distance(upper.position, lower.position), b = Vector3.Distance(lower.position, hand.position);
        Vector3 oldHand = hand.position;
        // Clearance is a continuous low-priority correction, not an immediate
        // replacement of the authored pose. Let its bounded offset converge.
        for (int frame = 0; frame <= 36; frame++) Call(guard, "ApplyAt", frame / 60f, true);
        float after = (float)Call(guard, "ArmClearance", true);
        Assert.That(Read<int>(guard, "CorrectedArms"), Is.GreaterThanOrEqualTo(1));
        Assert.That(after, Is.GreaterThan(before + .005f), "Correction must improve actual sampled clearance, not only report a successful gate.");
        Assert.That(Quaternion.Angle(hand.rotation, wrist), Is.LessThan(.03f), "Wrist world orientation is retained.");
        Assert.That(Vector3.Distance(oldHand, hand.position), Is.LessThan((a + b) * .451f));
        Assert.That(Vector3.Distance(upper.position, lower.position), Is.EqualTo(a).Within(.0001f));
        Assert.That(Vector3.Distance(lower.position, hand.position), Is.EqualTo(b).Within(.0001f));
        foreach (var pair in pose) if (f.Protected(pair.Key)) AssertLocalPose(pair.Key, pair.Value, "collision guard protected " + pair.Key.name);
        AssertMorphs(f, morphs);
        var once = f.LocalPoses();
        for (int repeat = 0; repeat < 30; repeat++) Call(guard, "ApplyAt", .6f, true);
        foreach (var pair in once) AssertLocalPose(pair.Key, pair.Value, "same-timestamp apply is idempotent " + pair.Key.name);
        Call(guard, "ApplyAt", .61f, false);
        Assert.That(Read<bool>(guard, "HasOwnedWrites"), Is.False);
        foreach (var pair in pose) AssertLocalPose(pair.Key, pair.Value, "gate restoration " + pair.Key.name);
    }

    [Test]
    public void UnmappedForeignModelCannotAcquireAnArmOrMicroMotionLease()
    {
        var foreign = new GameObject("unmapped foreign model");
        try
        {
            var animator = foreign.AddComponent<Animator>(); object guard = Activator.CreateInstance(Guard), micro = Activator.CreateInstance(Micro);
            Assert.That(Call(guard, "Bind", foreign.transform, animator), Is.False);
            Call(micro, "Bind", animator); Call(micro, "SetPhase", "listening", 0f);
            Call(micro, "Apply", 1f, true); Call(guard, "Apply", true);
            Assert.That(Read<bool>(micro, "HasOwnedWrites"), Is.False); Assert.That(Read<bool>(guard, "HasOwnedWrites"), Is.False);
            Assert.That(foreign.transform.position, Is.EqualTo(Vector3.zero));
        }
        finally { Object.DestroyImmediate(foreign); }
    }

    private static float DistanceToSegment(Vector3 p, Vector3 a, Vector3 b)
    { Vector3 d = b - a; float t = d.sqrMagnitude > 0f ? Mathf.Clamp01(Vector3.Dot(p - a, d) / d.sqrMagnitude) : 0f; return (p - a - d * t).magnitude; }
    private static void AssertLocalPose(Transform bone, (Vector3 position, Quaternion rotation) pose, string label)
    { Assert.That(Vector3.Distance(bone.localPosition, pose.position), Is.LessThan(.00001f), label); Assert.That(Quaternion.Angle(bone.localRotation, pose.rotation), Is.LessThan(.05f), label); }
    private static void AssertMorphs(Fixture f, Dictionary<SkinnedMeshRenderer, float[]> before)
    { foreach (var pair in before) for (int i = 0; i < pair.Value.Length; i++) Assert.That(pair.Key.GetBlendShapeWeight(i), Is.EqualTo(pair.Value[i]), pair.Key.name + " morph " + i); }

    private sealed class Fixture : IDisposable
    {
        public readonly GameObject Root;
        public readonly Animator Animator;
        private readonly Vrm10Instance vrm;
        private readonly Vrm10Runtime runtime;
        private readonly Dictionary<Renderer, Material[]> materials;
        private readonly HashSet<Transform> protectedBones = new();
        public Fixture()
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            Root = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm"));
            Root.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            materials = Root.GetComponentsInChildren<Renderer>(true).ToDictionary(r => r, r => r.sharedMaterials);
            Animator = Root.GetComponentInChildren<Animator>(); vrm = Root.GetComponentInChildren<Vrm10Instance>();
            if (vrm != null)
            {
                vrm.enabled = false; int slots = materials.Values.Sum(m => m.Count(v => v != null)); Assert.That(slots, Is.EqualTo(17));
                for (int i = 0; i < slots; i++) LogAssert.Expect(LogType.Error, "Instantiating material due to calling renderer.material during edit mode. This will leak materials into the scene. You most likely want to use renderer.sharedMaterial instead.");
                runtime = vrm.Runtime;
            }
            Animator.runtimeAnimatorController = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>("Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller");
            Animator.cullingMode = AnimatorCullingMode.AlwaysAnimate; Animator.applyRootMotion = false;
            Animator.Rebind(); Animator.Play("Base Layer.annie_idle_c", 0, .5f); Animator.Update(0f); runtime?.Process();
            protectedBones.Add(Root.transform);
            foreach (HumanBodyBones id in Enum.GetValues(typeof(HumanBodyBones)))
                if (id != HumanBodyBones.LastBone && (id.ToString().Contains("Leg") || id.ToString().Contains("Foot") || id.ToString().Contains("Toes") || id.ToString().Contains("Proximal") || id.ToString().Contains("Intermediate") || id.ToString().Contains("Distal") || id is HumanBodyBones.Hips or HumanBodyBones.Jaw or HumanBodyBones.LeftEye or HumanBodyBones.RightEye))
                { Transform bone = Bone(id); if (bone != null) protectedBones.Add(bone); }
        }
        public Transform Bone(HumanBodyBones id) => Animator.GetBoneTransform(id);
        public bool Protected(Transform bone) => protectedBones.Contains(bone);
        public Dictionary<Transform, (Vector3 position, Quaternion rotation)> LocalPoses() => Root.GetComponentsInChildren<Transform>(true).ToDictionary(t => t, t => (t.localPosition, t.localRotation));
        public Dictionary<SkinnedMeshRenderer, float[]> Morphs() => Root.GetComponentsInChildren<SkinnedMeshRenderer>(true).ToDictionary(r => r, r => Enumerable.Range(0, r.sharedMesh.blendShapeCount).Select(r.GetBlendShapeWeight).ToArray());
        public void Step() { Animator.Update(1f / 60f); runtime?.Process(); }
        public void Dispose()
        {
            var borrowed = new HashSet<Material>(materials.Values.SelectMany(m => m));
            var clones = materials.Keys.Where(r => r != null).SelectMany(r => r.sharedMaterials).Where(m => m != null && !borrowed.Contains(m) && !AssetDatabase.Contains(m)).Distinct().ToArray();
            foreach (var pair in materials) if (pair.Key != null) pair.Key.sharedMaterials = pair.Value;
            foreach (Material clone in clones) Object.DestroyImmediate(clone);
            if (runtime?.ControlRig != null) { Object.DestroyImmediate(runtime.ControlRig.ControlRigAnimator.avatar); Transform controls = vrm.transform.Find("Runtime Control Rig"); if (controls != null) Object.DestroyImmediate(controls.gameObject); }
            Object.DestroyImmediate(Root); EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        }
    }
}

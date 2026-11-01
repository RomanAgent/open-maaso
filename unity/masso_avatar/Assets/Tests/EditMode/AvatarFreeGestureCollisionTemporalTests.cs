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

public sealed class AvatarFreeGestureCollisionTemporalTests
{
    private static readonly Type Guard = Type.GetType("Maaso.Avatar.AvatarFreeGestureCollisionGuard, Assembly-CSharp", true);
    private static readonly Type Ik = Type.GetType("Maaso.Avatar.AvatarArmIk, Assembly-CSharp", true);
    private static object Call(object value, string method, params object[] args) => value.GetType().GetMethod(method).Invoke(value, args);
    private static T Read<T>(object value, string property) => (T)value.GetType().GetProperty(property).GetValue(value);

    [TestCase(30)]
    [TestCase(60)]
    public void FractionMillimetreClearanceCrossingsDoNotCreateCentimetreCorrectiveJumps(int fps)
    {
        using var f = new Fixture();
        object guard = Activator.CreateInstance(Guard);
        Assert.That(Call(guard, "Bind", f.Root.transform, f.Animator), Is.True, Read<string>(guard, "BindingDiagnostic"));
        var source = new BoundaryPose(f, guard);
        for (int frame = 0; frame <= 36; frame++)
        {
            source.Place(source.Boundary - .001f / source.TargetSpan);
            Call(guard, "ApplyAt", frame / 60f, true);
        }
        Assert.That(Read<int>(guard, "CorrectedArms"), Is.GreaterThan(0), "The boundary fixture must exercise a real corrective offset.");
        Quaternion previousUpperOffset = f.Upper.localRotation * Quaternion.Inverse(source.UpperSource);
        Quaternion previousLowerOffset = f.Lower.localRotation * Quaternion.Inverse(source.LowerSource);
        Vector3 previousWristOffset = f.Hand.position - source.WristSource;
        float maxOffsetStep = 0f, maxWristStep = 0f, maxSourceStep = 0f;
        Vector3 previousSource = source.WristSource;
        float armLength = Vector3.Distance(f.Upper.position, f.Lower.position), forearmLength = Vector3.Distance(f.Lower.position, f.Hand.position);
        for (int frame = 1; frame <= fps * 3; frame++)
        {
            float at = .6f + frame / (float)fps;
            // A smooth +/-0.2mm target perturbation crosses the exact sampled
            // body envelope. Its period is shorter than contact release grace.
            source.Place(source.Boundary + Mathf.Sin(frame / (float)fps * Mathf.PI * 8f) * (.0002f / source.TargetSpan));
            var before = f.Poses();
            Quaternion wrist = f.Hand.rotation;
            float sourceElbow = Vector3.Angle(f.Upper.position - f.Lower.position, f.Hand.position - f.Lower.position);
            maxSourceStep = Mathf.Max(maxSourceStep, Vector3.Distance(source.WristSource, previousSource));
            Call(guard, "ApplyAt", at, true);
            Quaternion upperOffset = f.Upper.localRotation * Quaternion.Inverse(source.UpperSource),
                lowerOffset = f.Lower.localRotation * Quaternion.Inverse(source.LowerSource);
            maxOffsetStep = Mathf.Max(maxOffsetStep, Quaternion.Angle(upperOffset, previousUpperOffset),
                Quaternion.Angle(lowerOffset, previousLowerOffset));
            Vector3 wristOffset = f.Hand.position - source.WristSource;
            maxWristStep = Mathf.Max(maxWristStep, Vector3.Distance(wristOffset, previousWristOffset));
            Assert.That(Quaternion.Angle(upperOffset, Quaternion.identity), Is.LessThanOrEqualTo(24.05f));
            Assert.That(Quaternion.Angle(lowerOffset, Quaternion.identity), Is.LessThanOrEqualTo(24.05f));
            Assert.That(Vector3.Angle(f.Upper.position - f.Lower.position, f.Hand.position - f.Lower.position),
                Is.GreaterThanOrEqualTo(Mathf.Min(55f, sourceElbow) - .2f), "Clearance may not sharpen the elbow beyond its anatomical bound.");
            Assert.That(Quaternion.Angle(f.Hand.rotation, wrist), Is.LessThan(.05f));
            f.AssertProtected(before);
            previousUpperOffset = upperOffset; previousLowerOffset = lowerOffset;
            previousWristOffset = wristOffset; previousSource = source.WristSource;
        }
        TestContext.WriteLine("Joy normalized" + " " + fps + "fps boundary: source max m=" + maxSourceStep +
            ", correction max deg/frame=" + maxOffsetStep + ", corrective wrist max m/frame=" + maxWristStep);
        Assert.That(maxSourceStep, Is.LessThan(.0015f), "The input must actually be sub-millimetre/smooth, not a jumping test pose.");
        Assert.That(maxOffsetStep, Is.LessThanOrEqualTo(60f / fps + .08f));
        float physicalWristBound = (armLength + 2f * forearmLength) * (60f / fps) * Mathf.Deg2Rad + .001f;
        Assert.That(maxWristStep, Is.LessThan(physicalWristBound), "Wrist correction must follow the same joint-rate bound rather than discretely selecting another ring target.");
        var lastSource = source.LastPose;
        Call(guard, "ApplyAt", 3.7f, false);
        Assert.That(Read<bool>(guard, "HasOwnedWrites"), Is.False);
        foreach (var pair in lastSource) AssertPose(pair.Key, pair.Value, "Task takeover releases immediately: " + pair.Key.name);
        f.AssertMeshUnchanged();
    }

    [Test]
    public void SameTimestampIsIdempotentAndLaterExternalOwnerSurvivesRelease()
    {
        using var f = new Fixture();
        object guard = Activator.CreateInstance(Guard);
        Assert.That(Call(guard, "Bind", f.Root.transform, f.Animator), Is.True, Read<string>(guard, "BindingDiagnostic"));
        var source = new BoundaryPose(f, guard);
        for (int frame = 0; frame <= 36; frame++)
        {
            source.Place(source.Boundary - .001f / source.TargetSpan);
            Call(guard, "ApplyAt", frame / 60f, true);
        }
        var once = f.Poses();
        for (int repeat = 0; repeat < 30; repeat++) Call(guard, "ApplyAt", .6f, true);
        foreach (var pair in once) AssertPose(pair.Key, pair.Value, "Repeated sample at the same time: " + pair.Key.name);
        Quaternion newerOwner = Quaternion.Euler(13f, 27f, -9f);
        f.Upper.localRotation = newerOwner;
        Call(guard, "ApplyAt", .61f, false);
        Assert.That(Read<bool>(guard, "HasOwnedWrites"), Is.False);
        Assert.That(Quaternion.Angle(f.Upper.localRotation, newerOwner), Is.LessThan(.03f), "A later task/IK owner is never restored over.");
    }

    private sealed class BoundaryPose
    {
        private readonly Fixture fixture;
        private readonly object guard;
        private readonly Dictionary<Transform, (Vector3 p, Quaternion q)> original;
        private readonly Vector3 inside, outside, side;
        public readonly float Boundary, TargetSpan;
        public Quaternion UpperSource, LowerSource;
        public Vector3 WristSource;
        public Dictionary<Transform, (Vector3 p, Quaternion q)> LastPose;

        public BoundaryPose(Fixture f, object value)
        {
            fixture = f; guard = value; original = f.Poses();
            inside = Vector3.Lerp(Read<Vector3>(guard, "TorsoStart"), Read<Vector3>(guard, "TorsoEnd"), .7f);
            side = Vector3.ProjectOnPlane(f.Upper.position - inside, f.Root.transform.up).normalized;
            float reach = Vector3.Distance(f.Upper.position, f.Lower.position) + Vector3.Distance(f.Lower.position, f.Hand.position);
            outside = f.Upper.position + side * (reach * .92f) - f.Root.transform.up * .08f;
            TargetSpan = Vector3.Distance(inside, outside);
            Place(0f); float a = (float)Call(guard, "ArmClearance", true);
            Place(1f); float b = (float)Call(guard, "ArmClearance", true);
            Assert.That(a, Is.LessThan(-.01f), "The boundary search must start inside the actual calibrated model envelope.");
            Assert.That(b, Is.GreaterThan(.001f), "The boundary search must end at a reachable clear source pose.");
            float low = 0f, high = 1f;
            for (int step = 0; step < 28; step++)
            {
                float middle = (low + high) * .5f;
                Place(middle);
                if ((float)Call(guard, "ArmClearance", true) < 0f) low = middle; else high = middle;
            }
            Boundary = (low + high) * .5f;
        }

        public void Place(float fraction)
        {
            Call(guard, "RestoreBeforeAnimation");
            foreach (var pair in original) { pair.Key.localPosition = pair.Value.p; pair.Key.localRotation = pair.Value.q; }
            Assert.That(Ik.GetMethod("Apply").Invoke(null, new object[] { fixture.Upper, fixture.Lower, fixture.Hand,
                Vector3.LerpUnclamped(inside, outside, fraction), side, 180f }), Is.EqualTo(true));
            UpperSource = fixture.Upper.localRotation; LowerSource = fixture.Lower.localRotation;
            WristSource = fixture.Hand.position; LastPose = fixture.Poses();
        }
    }

    private static void AssertPose(Transform bone, (Vector3 p, Quaternion q) pose, string message)
    {
        Assert.That(Vector3.Distance(bone.localPosition, pose.p), Is.LessThan(.00001f), message);
        Assert.That(Quaternion.Angle(bone.localRotation, pose.q), Is.LessThan(.05f), message);
    }

    private sealed class Fixture : IDisposable
    {
        public readonly GameObject Root;
        public readonly Animator Animator;
        public Transform Upper => Animator.GetBoneTransform(HumanBodyBones.LeftUpperArm);
        public Transform Lower => Animator.GetBoneTransform(HumanBodyBones.LeftLowerArm);
        public Transform Hand => Animator.GetBoneTransform(HumanBodyBones.LeftHand);
        private readonly Vrm10Instance vrm;
        private readonly Vrm10Runtime runtime;
        private readonly Dictionary<Renderer, Material[]> materials;
        private readonly HashSet<Transform> arms = new();
        private readonly Dictionary<Mesh, (Vector3[] normals, Matrix4x4[] bindposes)> meshData;
        public Fixture()
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            Root = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm"));
            Root.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            materials = Root.GetComponentsInChildren<Renderer>(true).ToDictionary(r => r, r => r.sharedMaterials);
            Animator = Root.GetComponentInChildren<Animator>(); vrm = Root.GetComponentInChildren<Vrm10Instance>();
            if (vrm != null)
            {
                vrm.enabled = false;
                typeof(Vrm10Instance).GetField("m_useControlRig", BindingFlags.Instance | BindingFlags.NonPublic).SetValue(vrm, true);
                int slots = materials.Values.Sum(m => m.Count(v => v != null)); Assert.That(slots, Is.EqualTo(17));
                for (int slot = 0; slot < slots; slot++) LogAssert.Expect(LogType.Error,
                    "Instantiating material due to calling renderer.material during edit mode. This will leak materials into the scene. You most likely want to use renderer.sharedMaterial instead.");
                runtime = vrm.Runtime;
            }
            Animator.runtimeAnimatorController = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>("Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller");
            Animator.cullingMode = AnimatorCullingMode.AlwaysAnimate; Animator.applyRootMotion = false;
            Animator.Rebind(); Animator.Play("Base Layer.annie_idle_c", 0, .5f); Animator.Update(0f); runtime?.Process();
            foreach (var id in new[] { HumanBodyBones.LeftUpperArm, HumanBodyBones.LeftLowerArm, HumanBodyBones.LeftHand,
                HumanBodyBones.RightUpperArm, HumanBodyBones.RightLowerArm, HumanBodyBones.RightHand }) arms.Add(Animator.GetBoneTransform(id));
            meshData = Root.GetComponentsInChildren<SkinnedMeshRenderer>(true).Select(r => r.sharedMesh).Distinct()
                .Where(m => m != null && m.isReadable).ToDictionary(m => m, m => (m.normals, m.bindposes));
        }
        public Dictionary<Transform, (Vector3 p, Quaternion q)> Poses() => Root.GetComponentsInChildren<Transform>(true)
            .ToDictionary(t => t, t => (t.localPosition, t.localRotation));
        public void AssertProtected(Dictionary<Transform, (Vector3 p, Quaternion q)> before)
        { foreach (var pair in before) if (!arms.Contains(pair.Key)) AssertPose(pair.Key, pair.Value, "Protected local channel " + pair.Key.name); }
        public void AssertMeshUnchanged()
        {
            foreach (var pair in meshData)
            {
                Assert.That(pair.Key.normals, Is.EqualTo(pair.Value.normals), "No mesh normal rewrite is allowed.");
                Assert.That(pair.Key.bindposes, Is.EqualTo(pair.Value.bindposes), "No bind-pose rewrite is allowed.");
            }
        }
        public void Dispose()
        {
            var original = new HashSet<Material>(materials.Values.SelectMany(m => m));
            var clones = materials.Keys.Where(r => r != null).SelectMany(r => r.sharedMaterials)
                .Where(m => m != null && !original.Contains(m) && !AssetDatabase.Contains(m)).Distinct().ToArray();
            foreach (var pair in materials) if (pair.Key != null) pair.Key.sharedMaterials = pair.Value;
            foreach (var clone in clones) Object.DestroyImmediate(clone);
            if (runtime?.ControlRig != null)
            {
                Object.DestroyImmediate(runtime.ControlRig.ControlRigAnimator.avatar);
                Transform controls = vrm.transform.Find("Runtime Control Rig");
                if (controls != null) Object.DestroyImmediate(controls.gameObject);
            }
            Object.DestroyImmediate(Root);
        }
    }
}

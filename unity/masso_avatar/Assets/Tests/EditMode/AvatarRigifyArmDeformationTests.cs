using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using Newtonsoft.Json.Linq;
using NUnit.Framework;
using UniVRM10;
using UnityEditor;
using UnityEngine;
using UnityEngine.TestTools;
using Object = UnityEngine.Object;

public sealed class AvatarRigifyArmDeformationTests
{
    private const string Model = "Assets/MaasoAvatar/Models/Default/Joy.vrm";
    private const string Golden = "Assets/Tests/EditMode/Editor/AvatarRigifyArmGolden.json";
    private static readonly Type Adapter = Type.GetType("Maaso.Avatar.AvatarRigifyArmDeformation, Assembly-CSharp", true);
    private static object Call(object value, string method, params object[] args) =>
        Adapter.GetMethod(method).Invoke(value, args);

    [Test]
    public void ActualSkinABindMatchesIndependentOriginalBlenderArmRest()
    {
        using var f = new Fixture();
        JObject golden = JObject.Parse(File.ReadAllText(Golden));
        var body = f.Avatar.GetComponentsInChildren<SkinnedMeshRenderer>(true).Single(r => r.name == "Joy_body");
        var bones = body.bones;
        var bindposes = body.sharedMesh.bindposes;
        foreach (var row in ((JObject)golden["rest_blender"]).Properties())
        {
            int index = Array.FindIndex(bones, bone => bone.name == row.Name);
            Assert.That(index, Is.GreaterThanOrEqualTo(0), row.Name);
            Matrix4x4 actual = body.transform.localToWorldMatrix * bindposes[index].inverse;
            Matrix4x4 expected = FromBlender(Matrix(row.Value), golden);
            AssertPose(actual, expected, row.Name + " actual A bind", .00002f, .01f);
        }
    }

    [TestCase("idle_c")]
    [TestCase("listen_b")]
    [TestCase("wave")]
    public void FullArmSkinningFramesMatchIndependentOriginalRigifyEvaluation(string clip)
    {
        using var f = new Fixture();
        JObject golden = JObject.Parse(File.ReadAllText(Golden));
        JObject sample = ((JArray)golden["samples"]).Cast<JObject>().Single(s => (string)s["clip"] == clip);
        SetInput(f, sample);
        var before = f.Avatar.GetComponentsInChildren<Transform>(true).ToDictionary(t => t, t => new Pose(t.position, t.rotation));
        var scales = before.Keys.ToDictionary(t => t, t => t.localScale);
        float rawUpperRollChange = 0f;
        Call(f.Helper, "ApplyAfterVrm");
        foreach (var row in ((JObject)sample["expected_source_deformers_blender"]).Properties())
        {
            Transform bone = f.Bone(row.Name);
            Matrix4x4 expected = FromBlender(Matrix(row.Value), golden);
            AssertPose(bone.localToWorldMatrix, expected, clip + "/" + row.Name, .001f, .1f);
            if (row.Name is "DEF-upper_arm.L" or "DEF-upper_arm.R")
                rawUpperRollChange = Mathf.Max(rawUpperRollChange, Quaternion.Angle(before[bone].rotation, bone.rotation));
        }
        if (clip is "idle_c" or "listen_b")
            Assert.That(rawUpperRollChange, Is.GreaterThan(20f), "The fixture must exercise the missing source roll, not an identity/no-op adapter.");
        AssertMappedJointsAndFingersPreserved(f, before);
        foreach (var pair in scales)
            Assert.That(pair.Key.localScale, Is.EqualTo(pair.Value), "Do not alter scales or recalculate bind poses: " + pair.Key.name);
    }

    [TestCase(.8f, 37f)]
    [TestCase(1.4f, -61f)]
    public void ModelRootTranslationRotationAndUniformScaleDoNotBecomeWorldSpaceConstants(float scale, float yaw)
    {
        using var f = new Fixture();
        f.Avatar.transform.SetPositionAndRotation(new Vector3(3f, .2f, -2f), Quaternion.Euler(0, yaw, 0));
        f.Avatar.transform.localScale = Vector3.one * scale;
        Assert.That(Call(f.Helper, "Bind", f.Avatar.transform), Is.True);
        JObject golden = JObject.Parse(File.ReadAllText(Golden));
        JObject sample = (JObject)golden["samples"][0];
        SetInput(f, sample);
        var before = f.Avatar.GetComponentsInChildren<Transform>(true).ToDictionary(t => t, t => new Pose(t.position, t.rotation));
        Call(f.Helper, "ApplyAfterVrm");
        foreach (var row in ((JObject)sample["expected_source_deformers_blender"]).Properties())
        {
            Matrix4x4 expected = f.Avatar.transform.localToWorldMatrix * FromBlender(Matrix(row.Value), golden);
            AssertPose(f.Bone(row.Name).localToWorldMatrix, expected, row.Name + " transformed actor", .001f, .1f);
        }
        AssertMappedJointsAndFingersPreserved(f, before);
    }

    [Test]
    public void RepeatedFramesRestoreOnlyOwnedLocalWritesAndNeverAccumulate()
    {
        using var f = new Fixture();
        JObject golden = JObject.Parse(File.ReadAllText(Golden));
        SetInput(f, (JObject)golden["samples"][0]);
        var initial = f.Avatar.GetComponentsInChildren<Transform>(true)
            .ToDictionary(t => t, t => (t.localPosition, t.localRotation));
        Call(f.Helper, "ApplyAfterVrm");
        var first = initial.Keys.ToDictionary(t => t, t => new Pose(t.position, t.rotation));
        for (int frame = 0; frame < 90; frame++) Call(f.Helper, "ApplyAfterVrm");
        foreach (var pair in first)
        {
            Assert.That(Vector3.Distance(pair.Key.position, pair.Value.position), Is.LessThan(.00001f), pair.Key.name);
            Assert.That(Quaternion.Angle(pair.Key.rotation, pair.Value.rotation), Is.LessThan(.05f), pair.Key.name);
        }
        Call(f.Helper, "RestoreBeforeAnimation");
        foreach (var pair in initial)
        {
            Assert.That(Vector3.Distance(pair.Key.localPosition, pair.Value.localPosition), Is.LessThan(.000001f), pair.Key.name);
            Assert.That(Quaternion.Angle(pair.Key.localRotation, pair.Value.localRotation), Is.LessThan(.05f), pair.Key.name);
        }
        Call(f.Helper, "ApplyAfterVrm");
        Transform upper = f.Bone("DEF-upper_arm.L");
        Quaternion takeover = Quaternion.Euler(18f, 24f, -11f);
        upper.localRotation = takeover;
        Call(f.Helper, "RestoreBeforeAnimation");
        Assert.That(Quaternion.Angle(upper.localRotation, takeover), Is.LessThan(.01f), "An external later owner must not be reverted.");
    }

    [Test]
    public void ActualNormalizedRigAndMouthFaceLegChannelsAreNeverWritten()
    {
        using var f = new Fixture(initializeVrm: true);
        var runtime = f.Vrm.Runtime;
        var controls = runtime.ControlRig.Bones.Values.ToDictionary(b => b.ControlBone,
            b => (b.ControlBone.localPosition, b.ControlBone.localRotation));
        JObject golden = JObject.Parse(File.ReadAllText(Golden));
        SetInput(f, (JObject)golden["samples"][0]);
        var morphs = f.Avatar.GetComponentsInChildren<SkinnedMeshRenderer>(true).ToDictionary(r => r,
            r => Enumerable.Range(0, r.sharedMesh.blendShapeCount).Select(r.GetBlendShapeWeight).ToArray());
        Call(f.Helper, "ApplyAfterVrm");
        foreach (var pair in controls)
        {
            Assert.That(pair.Key.localPosition, Is.EqualTo(pair.Value.localPosition), pair.Key.name);
            Assert.That(Quaternion.Angle(pair.Key.localRotation, pair.Value.localRotation), Is.LessThan(.01f), pair.Key.name);
        }
        foreach (var pair in morphs)
            Assert.That(Enumerable.Range(0, pair.Value.Length).Select(pair.Key.GetBlendShapeWeight), Is.EqualTo(pair.Value), pair.Key.name);
        var order = (DefaultExecutionOrder)Attribute.GetCustomAttribute(Adapter, typeof(DefaultExecutionOrder));
        Assert.That(order.order, Is.GreaterThan(11000), "Raw deformation runs after UniVRM, before the skin is rendered.");
    }

    [Test]
    public void ActualElbowSkinMatchesIndependentBlenderDeformerMatrices()
    {
        using var f = new Fixture();
        JObject golden = JObject.Parse(File.ReadAllText(Golden));
        JObject sample = (JObject)golden["samples"][0];
        SetInput(f, sample);
        var body = f.Avatar.GetComponentsInChildren<SkinnedMeshRenderer>(true).Single(r => r.name == "Joy_body");
        body.quality = SkinQuality.Bone4;
        Mesh source = body.sharedMesh;
        Vector3[] vertices = source.vertices;
        BoneWeight[] weights = source.boneWeights;
        Transform[] bones = body.bones;
        Matrix4x4[] bindposes = source.bindposes;
        Assert.That(vertices.Length, Is.EqualTo(weights.Length));
        var expectedMatrices = new Matrix4x4[bones.Length];
        var armBones = new bool[bones.Length];
        JObject reference = (JObject)sample["expected_source_deformers_blender"];
        for (int index = 0; index < bones.Length; index++)
        {
            // The oracle is Blender's independently evaluated original rig,
            // not the adapter's own roll formula. Other skin bones retain their
            // captured input matrix, so the test cannot hide unrelated changes.
            JToken expected = reference[bones[index].name];
            Matrix4x4 world = expected == null ? bones[index].localToWorldMatrix : FromBlender(Matrix(expected), golden);
            expectedMatrices[index] = world * bindposes[index];
            string name = bones[index].name;
            armBones[index] = name.StartsWith("DEF-upper_arm.", StringComparison.Ordinal) ||
                name.StartsWith("DEF-forearm.", StringComparison.Ordinal) ||
                name.StartsWith("DEF-elbow.", StringComparison.Ordinal) ||
                name.StartsWith("DEF-elbow_front.", StringComparison.Ordinal) ||
                name.StartsWith("DEF-hand.", StringComparison.Ordinal);
        }
        Vector3 leftElbow = f.Bone("DEF-forearm.L").position, rightElbow = f.Bone("DEF-forearm.R").position;
        var region = new List<int>();
        var expectedPoints = new Dictionary<int, Vector3>();
        for (int index = 0; index < vertices.Length; index++)
        {
            BoneWeight weight = weights[index];
            float armWeight = ArmWeight(weight.boneIndex0, weight.weight0) + ArmWeight(weight.boneIndex1, weight.weight1) +
                ArmWeight(weight.boneIndex2, weight.weight2) + ArmWeight(weight.boneIndex3, weight.weight3);
            if (armWeight < .95f) continue;
            Vector3 point = Skin(vertices[index], weight);
            if (Mathf.Min(Vector3.Distance(point, leftElbow), Vector3.Distance(point, rightElbow)) > .14f) continue;
            region.Add(index);
            expectedPoints.Add(index, point);
        }
        Assert.That(region.Count, Is.GreaterThan(500), "Exercise the actual body elbow skin, not a few hand bones or an empty region.");
        var baked = new Mesh();
        try
        {
            body.BakeMesh(baked);
            float before = MaximumError(baked.vertices);
            Assert.That(before, Is.GreaterThan(.01f), "The original input must reproduce centimetre-scale elbow deformation before correction.");
            Call(f.Helper, "ApplyAfterVrm");
            body.BakeMesh(baked);
            float after = MaximumError(baked.vertices);
            TestContext.WriteLine("Actual Joy elbow BakeMesh against Blender oracle: vertices=" + region.Count +
                ", before max m=" + before + ", after max m=" + after);
            Assert.That(after, Is.LessThan(.0001f), "The actual four-weight skin must match independent Blender deformation to 0.1 mm.");
        }
        finally { Object.DestroyImmediate(baked); }

        float ArmWeight(int index, float weight) => armBones[index] ? weight : 0f;
        Vector3 Skin(Vector3 vertex, BoneWeight weight) =>
            expectedMatrices[weight.boneIndex0].MultiplyPoint3x4(vertex) * weight.weight0 +
            expectedMatrices[weight.boneIndex1].MultiplyPoint3x4(vertex) * weight.weight1 +
            expectedMatrices[weight.boneIndex2].MultiplyPoint3x4(vertex) * weight.weight2 +
            expectedMatrices[weight.boneIndex3].MultiplyPoint3x4(vertex) * weight.weight3;
        float MaximumError(Vector3[] actual)
        {
            float maximum = 0f;
            foreach (int index in region)
                maximum = Mathf.Max(maximum, Vector3.Distance(body.transform.TransformPoint(actual[index]), expectedPoints[index]));
            return maximum;
        }
    }

    [Test]
    public void ForeignModelReplacementNullAndDisableReleaseWithoutTouchingTheirPose()
    {
        using var f = new Fixture();
        JObject golden = JObject.Parse(File.ReadAllText(Golden));
        SetInput(f, (JObject)golden["samples"][0]);
        Transform upper = f.Bone("DEF-upper_arm.L");
        Quaternion before = upper.localRotation;
        Call(f.Helper, "ApplyAfterVrm");
        f.Helper.enabled = false;
        // This production MonoBehaviour deliberately does not ExecuteAlways.
        // EditMode toggling does not dispatch Unity's play-mode lifecycle, so
        // invoke the same handler explicitly instead of changing runtime policy.
        Adapter.GetMethod("OnDisable", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(f.Helper, null);
        Assert.That(Quaternion.Angle(upper.localRotation, before), Is.LessThan(.05f));
        f.Helper.enabled = true;
        Assert.That((bool)Adapter.GetProperty("Bound").GetValue(f.Helper), Is.True, "Visibility disable is not a model replacement.");
        var matt = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>(Model));
        try
        {
            // A real humanoid without the VRM wrapper exercises the native
            // fallback without depending on a retired bundled character.
            Object.DestroyImmediate(matt.GetComponent<Vrm10Instance>());
            var pose = matt.GetComponentsInChildren<Transform>(true).ToDictionary(t => t, t => (t.localPosition, t.localRotation));
            Assert.That(Call(f.Helper, "Bind", matt.transform), Is.False);
            Call(f.Helper, "ApplyAfterVrm");
            foreach (var pair in pose)
            {
                Assert.That(pair.Key.localPosition, Is.EqualTo(pair.Value.localPosition));
                Assert.That(Quaternion.Angle(pair.Key.localRotation, pair.Value.localRotation), Is.LessThan(.01f));
            }
            Assert.That(Call(f.Helper, "Bind", new object[] { null }), Is.False);
        }
        finally { Object.DestroyImmediate(matt); }
    }

    private static void SetInput(Fixture f, JObject sample)
    {
        foreach (string side in new[] { "L", "R" })
        {
            Matrix4x4 shoulder = Matrix(sample["input_unity_shoulders"][side == "L" ? "LeftShoulder" : "RightShoulder"]);
            Place(f.Bone("DEF-shoulder." + side), f.Avatar.transform.localToWorldMatrix * shoulder);
            foreach (string name in new[] { "DEF-upper_arm." + side, "DEF-upper_arm." + side + ".001",
                "DEF-elbow." + side, "DEF-elbow_front." + side, "DEF-forearm." + side,
                "DEF-forearm." + side + ".001", "DEF-hand." + side })
                Place(f.Bone(name), f.Avatar.transform.localToWorldMatrix * Matrix(sample["input_unity_deformers"][name]));
        }
    }

    private static void AssertMappedJointsAndFingersPreserved(Fixture f, Dictionary<Transform, Pose> before)
    {
        foreach (HumanBodyBones id in Enum.GetValues(typeof(HumanBodyBones)))
        {
            if (id == HumanBodyBones.LastBone || !f.Vrm.TryGetBoneTransform(id, out var bone) || bone == null) continue;
            Assert.That(Vector3.Distance(bone.position, before[bone].position), Is.LessThan(.00001f), id + " joint endpoint");
            if (id is not (HumanBodyBones.LeftUpperArm or HumanBodyBones.RightUpperArm))
                Assert.That(Quaternion.Angle(bone.rotation, before[bone].rotation), Is.LessThan(.05f), id + " world orientation");
        }
        Assert.That(f.Avatar.transform.position, Is.EqualTo(before[f.Avatar.transform].position));
        Assert.That(Quaternion.Angle(f.Avatar.transform.rotation, before[f.Avatar.transform].rotation), Is.LessThan(.01f));
    }

    private static void Place(Transform bone, Matrix4x4 matrix) =>
        bone.SetPositionAndRotation(matrix.GetColumn(3), Rotation(matrix));
    private static Quaternion Rotation(Matrix4x4 matrix) => Quaternion.LookRotation(matrix.GetColumn(2), matrix.GetColumn(1));
    private static Matrix4x4 Matrix(JToken value)
    {
        var matrix = new Matrix4x4();
        for (int row = 0; row < 4; row++)
            for (int column = 0; column < 4; column++) matrix[row, column] = (float)value[row][column];
        return matrix;
    }
    private static Matrix4x4 FromBlender(Matrix4x4 matrix, JObject golden)
    {
        Matrix4x4 b = Matrix(golden["basis_blender_to_gltf"]), x = Matrix(golden["basis_gltf_to_unity_reflection"]);
        return x * b * matrix * x;
    }
    private static void AssertPose(Matrix4x4 actual, Matrix4x4 expected, string label, float positionTolerance, float rotationTolerance)
    {
        float position = Vector3.Distance(actual.GetColumn(3), expected.GetColumn(3));
        float angle = Quaternion.Angle(Rotation(actual), Rotation(expected));
        TestContext.WriteLine(label + ": position m=" + position + ", rotation deg=" + angle);
        Assert.That(position, Is.LessThan(positionTolerance), label);
        Assert.That(angle, Is.LessThan(rotationTolerance), label);
    }

    private sealed class Fixture : IDisposable
    {
        public readonly GameObject Avatar;
        public readonly Vrm10Instance Vrm;
        public readonly Behaviour Helper;
        private readonly Dictionary<Renderer, Material[]> originalMaterials;

        public Fixture(bool initializeVrm = false)
        {
            Avatar = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>(Model));
            Avatar.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            Avatar.transform.localScale = Vector3.one;
            Vrm = Avatar.GetComponent<Vrm10Instance>();
            Vrm.enabled = false;
            originalMaterials = Avatar.GetComponentsInChildren<Renderer>(true).ToDictionary(r => r, r => r.sharedMaterials);
            if (initializeVrm)
            {
                int clones = originalMaterials.Values.Sum(materials => materials.Count(m => m != null));
                Assert.That(clones, Is.EqualTo(17), "Reviewed source Joy material slot count.");
                for (int slot = 0; slot < clones; slot++) LogAssert.Expect(LogType.Error,
                    "Instantiating material due to calling renderer.material during edit mode. This will leak materials into the scene. You most likely want to use renderer.sharedMaterial instead.");
                // Match the runtime loader before the lazy Runtime property
                // constructs its owner; prefab instances default this to false.
                typeof(Vrm10Instance).GetField("m_useControlRig", BindingFlags.Instance | BindingFlags.NonPublic)
                    .SetValue(Vrm, true);
                _ = Vrm.Runtime;
            }
            Helper = (Behaviour)Avatar.AddComponent(Adapter);
            Assert.That(Call(Helper, "Bind", Avatar.transform), Is.True, "Actual shipped Joy must match the reviewed deformation profile.");
        }

        public Transform Bone(string name) => Avatar.GetComponentsInChildren<Transform>(true).Single(t => t.name == name);

        public void Dispose()
        {
            var original = new HashSet<Material>(originalMaterials.Values.SelectMany(m => m));
            var clones = originalMaterials.Keys.Where(r => r != null).SelectMany(r => r.sharedMaterials)
                .Where(m => m != null && !original.Contains(m) && !AssetDatabase.Contains(m)).Distinct().ToArray();
            foreach (var pair in originalMaterials) if (pair.Key != null) pair.Key.sharedMaterials = pair.Value;
            foreach (var material in clones) Object.DestroyImmediate(material);
            // Do not invoke Vrm.Runtime here: most fixtures intentionally never
            // initialize a second normalized owner just to inspect raw skin data.
            Transform controls = Avatar.transform.Find("Runtime Control Rig");
            if (controls != null)
            {
                var animator = Avatar.GetComponent<Animator>();
                if (animator != null && animator.avatar != null && !AssetDatabase.Contains(animator.avatar))
                    Object.DestroyImmediate(animator.avatar);
                Object.DestroyImmediate(controls.gameObject);
            }
            Object.DestroyImmediate(Avatar);
        }
    }
}

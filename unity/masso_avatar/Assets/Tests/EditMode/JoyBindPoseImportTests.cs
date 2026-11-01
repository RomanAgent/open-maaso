using System;
using System.IO;
using System.Linq;
using System.Text;
using Newtonsoft.Json.Linq;
using NUnit.Framework;
using UnityEditor;
using UnityEngine;
using Object = UnityEngine.Object;

/// <summary>
/// Joy keeps its authored A-pose mesh/bind matrices while its glTF nodes provide
/// the Humanoid T pose. Importing must not silently replace those matrices with
/// the inverse of the current T-pose joint transforms.
/// </summary>
public sealed class JoyBindPoseImportTests
{
    private const string ModelPath = "Assets/MaasoAvatar/Models/Default/Joy.vrm";

    [Test]
    public void ImportedBindMatricesMatchEverySourceSkinJointWithoutRecalculation()
    {
        var source = new SourceVrm();
        GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(ModelPath);
        Assert.That(prefab, Is.Not.Null);
        GameObject instance = Object.Instantiate(prefab);
        try
        {
            var renderers = instance.GetComponentsInChildren<SkinnedMeshRenderer>(true);
            int checkedMatrices = 0;
            float maximumImporterResidual = 0f;
            float maximumExactElementDifference = 0f;
            float maximumExactPointDifference = 0f;
            string worstImporterResidual = string.Empty;
            string worstPointDifference = string.Empty;
            // Two-metre radial probes bound displacement at avatar scale rather
            // than granting a larger arbitrary tolerance to rotation coefficients.
            Vector3[] probes = { Vector3.zero, Vector3.right * 2f, Vector3.left * 2f,
                Vector3.up * 2f, Vector3.down * 2f, Vector3.forward * 2f, Vector3.back * 2f };
            foreach (JToken node in source.Document["nodes"])
            {
                if (node["mesh"] == null || node["skin"] == null) continue;
                string nodeName = node["name"].Value<string>();
                SkinnedMeshRenderer renderer = renderers.SingleOrDefault(item => item.name == nodeName);
                Assert.That(renderer, Is.Not.Null, nodeName);
                Assert.That(renderer.sharedMesh, Is.Not.Null, nodeName);
                JToken skin = source.Document["skins"][node["skin"].Value<int>()];
                Matrix4x4[] expected = source.InverseBindMatrices(skin, out Matrix4x4[] exact);
                Matrix4x4[] actual = renderer.sharedMesh.bindposes;
                Assert.That(actual.Length, Is.EqualTo(expected.Length), nodeName);
                Assert.That(renderer.bones.Length, Is.EqualTo(expected.Length), nodeName);
                for (int joint = 0; joint < expected.Length; joint++)
                {
                    string jointName = source.Document["nodes"][skin["joints"][joint].Value<int>()]
                        ["name"].Value<string>();
                    Assert.That(renderer.bones[joint].name, Is.EqualTo(jointName), nodeName);
                    string label = nodeName + "/" + jointName;
                    float residual = MaximumMatrixDifference(actual[joint], expected[joint]);
                    if (residual > maximumImporterResidual)
                    {
                        maximumImporterResidual = residual;
                        worstImporterResidual = label;
                    }
                    maximumExactElementDifference = Mathf.Max(maximumExactElementDifference,
                        MaximumMatrixDifference(actual[joint], exact[joint]));
                    foreach (Vector3 probe in probes)
                    {
                        float distance = Vector3.Distance(actual[joint].MultiplyPoint3x4(probe),
                            exact[joint].MultiplyPoint3x4(probe));
                        if (float.IsNaN(distance) || float.IsInfinity(distance)) distance = float.PositiveInfinity;
                        if (distance > maximumExactPointDifference)
                        {
                            maximumExactPointDifference = distance;
                            worstPointDifference = label;
                        }
                    }
                    checkedMatrices++;
                }
            }
            Assert.That(checkedMatrices, Is.GreaterThan(100),
                "Check the actual imported skin data, not an empty or synthetic model.");
            Debug.Log($"[JoyBindPoseImport] matrices={checkedMatrices}, " +
                $"allMaxImporterResidual={maximumImporterResidual:R} ({worstImporterResidual}), " +
                $"allMaxExactElementDifference={maximumExactElementDifference:R}, " +
                $"allMaxExactPointDifferenceMeters={maximumExactPointDifference:R} ({worstPointDifference})");
            Assert.That(maximumImporterResidual, Is.LessThanOrEqualTo(0.00002f), worstImporterResidual);
            Assert.That(maximumExactPointDifference, Is.LessThanOrEqualTo(0.001f),
                "Source A-pose IBM must retain sub-millimetre point accuracy across the two-metre probes: " +
                worstPointDifference);
        }
        finally
        {
            Object.DestroyImmediate(instance);
        }
    }

    [TestCase("leftUpperArm", "leftLowerArm")]
    [TestCase("rightUpperArm", "rightLowerArm")]
    public void AuthoredArmBindPoseRemainsAWhileImportedJointNodesProvideT(
        string upperArmName, string lowerArmName)
    {
        var source = new SourceVrm();
        JToken humanBones = source.Document["extensions"]["VRMC_vrm"]["humanoid"]["humanBones"];
        int upperNode = humanBones[upperArmName]["node"].Value<int>();
        int lowerNode = humanBones[lowerArmName]["node"].Value<int>();
        string upperName = source.Document["nodes"][upperNode]["name"].Value<string>();
        string lowerName = source.Document["nodes"][lowerNode]["name"].Value<string>();
        GameObject instance = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>(ModelPath));
        try
        {
            var renderer = instance.GetComponentsInChildren<SkinnedMeshRenderer>(true)
                .Single(item => item.name == "Joy_body");
            int upperIndex = Array.FindIndex(renderer.bones, bone => bone.name == upperName);
            int lowerIndex = Array.FindIndex(renderer.bones, bone => bone.name == lowerName);
            Assert.That(upperIndex, Is.GreaterThanOrEqualTo(0));
            Assert.That(lowerIndex, Is.GreaterThanOrEqualTo(0));
            Matrix4x4[] bindposes = renderer.sharedMesh.bindposes;
            Vector3 bindShoulder = bindposes[upperIndex].inverse.MultiplyPoint3x4(Vector3.zero);
            Vector3 bindElbow = bindposes[lowerIndex].inverse.MultiplyPoint3x4(Vector3.zero);
            Vector3 bindArm = (bindElbow - bindShoulder).normalized;
            Vector3 nodeArm = renderer.transform.InverseTransformVector(
                renderer.bones[lowerIndex].position - renderer.bones[upperIndex].position).normalized;

            Assert.That(bindArm.y, Is.LessThan(-0.15f),
                "The authored A-pose arm must slope down in bind space: " + upperName);
            Assert.That(Mathf.Abs(nodeArm.y), Is.LessThan(0.15f),
                "The imported Humanoid reference nodes must still form the T pose: " + upperName);
            Assert.That(Vector3.Angle(bindArm, nodeArm), Is.GreaterThan(10f),
                "A bind pose must not be replaced with the inverse of the current T nodes.");
        }
        finally
        {
            Object.DestroyImmediate(instance);
        }
    }

    private static float MaximumMatrixDifference(Matrix4x4 actual, Matrix4x4 expected)
    {
        float maximum = 0f;
        for (int row = 0; row < 4; row++)
        for (int column = 0; column < 4; column++)
        {
            float difference = Mathf.Abs(actual[row, column] - expected[row, column]);
            if (float.IsNaN(difference) || float.IsInfinity(difference)) return float.PositiveInfinity;
            maximum = Mathf.Max(maximum, difference);
        }
        return maximum;
    }

    private sealed class SourceVrm
    {
        private readonly byte[] bytes = File.ReadAllBytes(ModelPath);
        private readonly int binaryOffset;
        public JObject Document { get; }

        public SourceVrm()
        {
            Assert.That(BitConverter.ToUInt32(bytes, 0), Is.EqualTo(0x46546C67u));
            Assert.That(BitConverter.ToUInt32(bytes, 4), Is.EqualTo(2u));
            int jsonLength = BitConverter.ToInt32(bytes, 12);
            Assert.That(BitConverter.ToUInt32(bytes, 16), Is.EqualTo(0x4E4F534Au));
            Document = JObject.Parse(Encoding.UTF8.GetString(bytes, 20, jsonLength));
            Assert.That(BitConverter.ToUInt32(bytes, 24 + jsonLength), Is.EqualTo(0x004E4942u));
            binaryOffset = 28 + jsonLength;
        }

        public Matrix4x4[] InverseBindMatrices(JToken skin, out Matrix4x4[] exact)
        {
            Assert.That(skin["inverseBindMatrices"], Is.Not.Null,
                "A-pose skin must carry explicit inverse bind matrices.");
            JToken accessor = Document["accessors"][skin["inverseBindMatrices"].Value<int>()];
            Assert.That(accessor["type"].Value<string>(), Is.EqualTo("MAT4"));
            Assert.That(accessor["componentType"].Value<int>(), Is.EqualTo(5126));
            Assert.That(accessor["sparse"], Is.Null);
            JToken view = Document["bufferViews"][accessor["bufferView"].Value<int>()];
            Assert.That(view["buffer"].Value<int>(), Is.Zero);
            int offset = binaryOffset + (view["byteOffset"]?.Value<int>() ?? 0)
                + (accessor["byteOffset"]?.Value<int>() ?? 0);
            int stride = view["byteStride"]?.Value<int>() ?? 64;
            var matrices = new Matrix4x4[accessor["count"].Value<int>()];
            exact = new Matrix4x4[matrices.Length];
            Matrix4x4 reverseX = Matrix4x4.Scale(new Vector3(-1, 1, 1));
            for (int matrix = 0; matrix < matrices.Length; matrix++)
            {
                var gltf = new Matrix4x4();
                for (int column = 0; column < 4; column++)
                for (int row = 0; row < 4; row++)
                    gltf[row, column] = BitConverter.ToSingle(bytes,
                        offset + matrix * stride + (column * 4 + row) * 4);
                exact[matrix] = reverseX * gltf * reverseX;
                // Verified UniGLTF ReverseX(Matrix4x4) decomposes TRS and converts
                // the quaternion through angle/axis. Near-zero rotations incur
                // float acos quantization, so it is not bit-equivalent to S*M*S.
                // Recreate that coordinate conversion from SOURCE matrices only;
                // the separate exact point bound above limits physical error.
                gltf.rotation.ToAngleAxis(out float angle, out Vector3 axis);
                axis.x = -axis.x;
                var scale = new Vector3(gltf.GetColumn(0).magnitude,
                    gltf.GetColumn(1).magnitude, gltf.GetColumn(2).magnitude);
                matrices[matrix] = Matrix4x4.TRS(new Vector3(-gltf.m03, gltf.m13, gltf.m23),
                    Quaternion.AngleAxis(-angle, axis), scale);
            }
            return matrices;
        }
    }
}

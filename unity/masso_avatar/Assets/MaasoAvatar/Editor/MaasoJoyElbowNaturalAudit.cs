#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using Newtonsoft.Json.Linq;
using Maaso.Avatar;
using UniVRM10;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using Object = UnityEngine.Object;

namespace Maaso.Avatar.Editor
{
    // Diagnostic only. All original source assets remain read-only. Source
    // matrices are the actual evaluated Blender deform matrices, not guessed
    // Animator muscle values or an independently timed animation.
    public static class MaasoJoyElbowNaturalAudit
    {
        private const string Model = "Assets/MaasoAvatar/Models/Default/Joy.vrm";
        private const BindingFlags PrivateStatic = BindingFlags.Static | BindingFlags.NonPublic;
        public static void Run()
        {
            string input = Environment.GetEnvironmentVariable("MAASO_ELBOW_SOURCE_DIAGNOSTIC") ??
                "/private/tmp/maaso-elbow-natural-20261016/source/source-elbow-diagnostic.json";
            string output = Environment.GetEnvironmentVariable("MAASO_ELBOW_UNITY_OUTPUT") ??
                "/private/tmp/maaso-elbow-natural-20261016/unity";
            Directory.CreateDirectory(output);
            var rows = new JArray();
            foreach (JObject pose in JObject.Parse(File.ReadAllText(input))["poses"]) rows.Add(Pose(pose, output));
            byte[] profileBytes = File.ReadAllBytes("Assets/Resources/MaasoAvatar/joy_elbow_correctives.json");
            using var sha = System.Security.Cryptography.SHA256.Create();
            File.WriteAllText(Path.Combine(output, "receipt.json"), new JObject {
                ["profileSha256"] = BitConverter.ToString(sha.ComputeHash(profileBytes)).Replace("-", "").ToLowerInvariant(),
                ["scope"] = "Source mapped-joint pose with rigid TRS restoration residuals explicitly reported. A=current runtime profile identified by SHA256, B=same A positions with source normals, C=source exact elbow positions/normals. C does not claim all source affine matrices fit Unity TRS. Original source fold is not a naturalness certificate.",
                ["poses"] = rows }.ToString());
            Debug.Log("Elbow surface ablation completed: " + output);
        }
        private static JObject Pose(JObject source, string output)
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            GameObject root = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>(Model));
            root.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity); root.transform.localScale = Vector3.one;
            root.GetComponent<Vrm10Instance>().enabled = false;
            var animator = root.GetComponent<Animator>(); animator.enabled = false; animator.runtimeAnimatorController = null;
            var body = root.GetComponentsInChildren<SkinnedMeshRenderer>(true).Single(r => r.name == "Joy_body");
            body.quality = SkinQuality.Bone4;
            var bones = body.bones.ToDictionary(b => b.name, StringComparer.Ordinal);
            var reference = (JObject)source["allDeformMatricesUnity"];
            var defaults = new JObject();
            for (int i = 0; i < body.sharedMesh.blendShapeCount; i++)
                if (body.sharedMesh.GetBlendShapeName(i).Contains("upperarm")) defaults[body.sharedMesh.GetBlendShapeName(i)] = body.GetBlendShapeWeight(i);
            foreach (var bone in body.bones.OrderBy(Depth))
            {
                if (reference[bone.name] == null) throw new InvalidDataException("Source deform matrix missing: " + bone.name);
                Matrix4x4 target = Matrix(reference[bone.name]);
                // The source may contain inherited affine shear on unrelated
                // facial/outfit helpers. Preserve the imported local scales;
                // restore the rigid joint frame and measure, never conceal,
                // every nonrepresentable part of the original source matrix.
                bone.SetPositionAndRotation(target.GetColumn(3),
                    Quaternion.LookRotation(target.GetColumn(2), target.GetColumn(1)));
            }
            var armIndices = new HashSet<int>();
            BoneWeight[] skinWeights = body.sharedMesh.boneWeights;
            foreach (string side in new[] { "L", "R" })
                foreach (int index in source["stages"]["source-smooth"][side]["portableIndices"].Values<int>())
                {
                    BoneWeight w = skinWeights[index];
                    if (w.weight0 > .000001f) armIndices.Add(w.boneIndex0);
                    if (w.weight1 > .000001f) armIndices.Add(w.boneIndex1);
                    if (w.weight2 > .000001f) armIndices.Add(w.boneIndex2);
                    if (w.weight3 > .000001f) armIndices.Add(w.boneIndex3);
                }
            var restoreErrors = new List<(string name, float value, bool arm)>();
            for (int boneIndex = 0; boneIndex < body.bones.Length; boneIndex++)
            {
                Transform bone = body.bones[boneIndex];
                Matrix4x4 actual = bone.localToWorldMatrix, expected = Matrix(reference[bone.name]);
                float error = 0; for (int i = 0; i < 16; i++) error = Mathf.Max(error, Mathf.Abs(actual[i] - expected[i]));
                restoreErrors.Add((bone.name, error, armIndices.Contains(boneIndex)));
            }
            float matrixError = restoreErrors.Max(row => row.value);
            float armMatrixError = restoreErrors.Where(row => row.arm).Max(row => row.value);
            float jointError = new[] { "DEF-upper_arm.L", "DEF-forearm.L", "DEF-hand.L", "DEF-upper_arm.R", "DEF-forearm.R", "DEF-hand.R" }
                .Max(name => Vector3.Distance(bones[name].position, Matrix(reference[name]).GetColumn(3)));
            var deformation = root.AddComponent<AvatarRigifyArmDeformation>();
            var corrective = root.AddComponent<AvatarJoyElbowCorrectives>();
            var meshes = new List<Mesh>();
            Material neutral = null;
            var result = new JObject { ["clip"] = source["clip"], ["timeSeconds"] = source["timeSeconds"],
                ["sourceCoreJointMaxMeters"] = source["coreJointMaxMeters"], ["unityCoreJointRestoreMaxMeters"] = jointError,
                ["allSkinMatrixRestoreMaxAbs"] = matrixError, ["elbowInfluencingSkinMatrixRestoreMaxAbs"] = armMatrixError,
                ["worstRestoredMatrices"] = new JArray(restoreErrors.OrderByDescending(row => row.value).Take(12)
                    .Select(row => new JObject { ["bone"] = row.name, ["maxAbs"] = row.value, ["elbowInfluence"] = row.arm })),
                ["worstElbowMatrices"] = new JArray(restoreErrors.Where(row => row.arm).OrderByDescending(row => row.value)
                    .Select(row => new JObject { ["bone"] = row.name, ["maxAbs"] = row.value })),
                ["portableUpperarmDefaultWeights"] = defaults, ["sourceDriverValues"] = source["armShapeDrivers"].DeepClone() };
            try
            {
                File.WriteAllText(Path.Combine(output, (string)source["clip"] + "-pose-restore.json"), result.ToString());
                Debug.Log("Elbow source pose restore: " + result);
                Require(jointError < .00005f, "Source core joints could not be restored within50micrometers; visual comparison aborted");
                result["independentFullAffineLbs"] = CompareAffineLbs(body, reference, source);
                Require(deformation.Bind(root.transform), "Rigify bind failed");
                Require(corrective.Bind(root.transform), "Elbow bind failed: " + corrective.LastFailure);
                deformation.ApplyAfterVrm(); corrective.ApplyAfterVrm();
                var current = new Mesh { name = "Elbow audit R80" }; body.BakeMesh(current); meshes.Add(current);
                var normalOnly = Object.Instantiate(current); normalOnly.name = "Elbow audit exact normals only"; meshes.Add(normalOnly);
                var exact = Object.Instantiate(current); exact.name = "Elbow audit exact source surface"; meshes.Add(exact);
                var normals = normalOnly.normals; var exactNormals = exact.normals; var points = exact.vertices;
                foreach (string side in new[] { "L", "R" })
                {
                    JObject target = (JObject)source["stages"]["source-smooth"][side];
                    int[] ids = target["portableIndices"].ToObject<int[]>();
                    for (int i = 0; i < ids.Length; i++)
                    {
                        Vector3 n = body.transform.InverseTransformDirection(Vector(target["normalsUnity"][i])).normalized;
                        normals[ids[i]] = n; exactNormals[ids[i]] = n;
                        points[ids[i]] = body.transform.InverseTransformPoint(Vector(target["positionsUnity"][i]));
                    }
                }
                normalOnly.normals = normals; exact.vertices = points; exact.normals = exactNormals; exact.RecalculateBounds();
                result["geometry"] = Compare(current, body.transform, source);
                var weights = new JObject();
                for (int i = 0; i < body.sharedMesh.blendShapeCount; i++)
                    if (body.sharedMesh.GetBlendShapeName(i).StartsWith("Maaso.Joy.Elbow.", StringComparison.Ordinal)) weights[body.sharedMesh.GetBlendShapeName(i)] = body.GetBlendShapeWeight(i);
                result["currentCorrectiveWeights"] = weights;
                Camera camera = (Camera)typeof(MaasoSpeechPerformanceReplay).GetMethod("CreateCamera", PrivateStatic).Invoke(null, new object[] { root });
                Shader shader = Shader.Find("Universal Render Pipeline/Lit") ?? Shader.Find("Standard");
                Require(shader != null, "Neutral diagnostic shader missing"); neutral = new Material(shader);
                if (neutral.HasProperty("_BaseColor")) neutral.SetColor("_BaseColor", new Color(.55f, .60f, .65f));
                if (neutral.HasProperty("_Color")) neutral.SetColor("_Color", new Color(.55f, .60f, .65f));
                if (neutral.HasProperty("_Smoothness")) neutral.SetFloat("_Smoothness", 0f);
                if (neutral.HasProperty("_Glossiness")) neutral.SetFloat("_Glossiness", 0f);
                var rendered = new JArray();
                var stages = new List<(string name, Mesh mesh)> {
                    ("A-current", current), ("B-source-normals-only", normalOnly), ("C-source-surface", exact) };
                string naturalPath = Environment.GetEnvironmentVariable("MAASO_ELBOW_NATURAL_CANDIDATE");
                if (!string.IsNullOrEmpty(naturalPath))
                {
                    JObject naturalPose = JObject.Parse(File.ReadAllText(naturalPath))["poses"].OfType<JObject>()
                        .Single(p => (string)p["clip"] == (string)source["clip"]);
                    JObject candidate = (JObject)naturalPose["candidates"]["actual-R80-Taubin48-8mm"];
                    var naturalNormalsOnly = Object.Instantiate(current); meshes.Add(naturalNormalsOnly);
                    var naturalExact = Object.Instantiate(current); meshes.Add(naturalExact);
                    Vector3[] ns = naturalNormalsOnly.normals, ps = naturalExact.vertices;
                    foreach (string side in new[] { "L", "R" })
                    {
                        JObject target = (JObject)candidate["elbows"][side];
                        int[] ids = target["portableIndices"].ToObject<int[]>();
                        for (int i = 0; i < ids.Length; i++)
                        {
                            ns[ids[i]] = body.transform.InverseTransformDirection(Vector(target["normalsUnity"][i])).normalized;
                            ps[ids[i]] = body.transform.InverseTransformPoint(Vector(target["positionsUnity"][i]));
                        }
                    }
                    naturalNormalsOnly.normals = ns;
                    naturalExact.vertices = ps; naturalExact.normals = ns; naturalExact.RecalculateBounds();
                    stages.Add(("D-natural-normals-only", naturalNormalsOnly));
                    stages.Add(("E-natural-exact", naturalExact));
                }
                foreach (var stage in stages)
                {
                    foreach (bool matte in new[] { false, true })
                    {
                        var snapshot = new GameObject("Static elbow surface ablation"); snapshot.transform.SetParent(body.transform, false);
                        snapshot.AddComponent<MeshFilter>().sharedMesh = stage.mesh;
                        snapshot.AddComponent<MeshRenderer>().sharedMaterials = matte ? Enumerable.Repeat(neutral, body.sharedMaterials.Length).ToArray() : body.sharedMaterials;
                        body.enabled = false;
                        foreach (string side in new[] { "L", "R" })
                        {
                            Vector3 target = Vector(source["stages"]["source-smooth"][side]["elbowUnity"]);
                            camera.fieldOfView = 35f; camera.transform.position = target + Vector3.forward * .55f; camera.transform.LookAt(target);
                            string path = Path.Combine(output, (string)source["clip"] + "-" + stage.name + (matte ? "-neutral-" : "-material-") + side + ".png");
                            typeof(MaasoSpeechPerformanceReplay).GetMethod("Render", PrivateStatic).Invoke(null, new object[] { camera, root, path });
                            rendered.Add(new JObject { ["stage"] = stage.name, ["neutral"] = matte, ["side"] = side, ["path"] = path });
                        }
                        Object.DestroyImmediate(snapshot); body.enabled = true;
                    }
                }
                result["renders"] = rendered;
                return result;
            }
            finally
            {
                corrective.Reset(); deformation.Reset();
                foreach (Mesh mesh in meshes) Object.DestroyImmediate(mesh);
                if (neutral != null) Object.DestroyImmediate(neutral);
                Object.DestroyImmediate(root);
                EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            }
        }
        private static JObject CompareAffineLbs(SkinnedMeshRenderer body, JObject reference, JObject source)
        {
            Mesh mesh = body.sharedMesh; Vector3[] points = mesh.vertices; BoneWeight[] weights = mesh.boneWeights;
            Matrix4x4[] inverse = mesh.bindposes;
            Matrix4x4[] full = body.bones.Select((bone, index) => Matrix(reference[bone.name]) * inverse[index]).ToArray();
            var result = new JObject();
            foreach (string side in new[] { "L", "R" })
            {
                JObject target = (JObject)source["stages"]["source-lbs"][side];
                int[] ids = target["portableIndices"].ToObject<int[]>(); var distances = new List<float>();
                foreach (var pair in ids.Select((index, ordinal) => (index, ordinal)))
                {
                    BoneWeight w = weights[pair.index]; Vector3 p = points[pair.index];
                    Vector3 actual = full[w.boneIndex0].MultiplyPoint3x4(p) * w.weight0 + full[w.boneIndex1].MultiplyPoint3x4(p) * w.weight1 +
                        full[w.boneIndex2].MultiplyPoint3x4(p) * w.weight2 + full[w.boneIndex3].MultiplyPoint3x4(p) * w.weight3;
                    distances.Add(Vector3.Distance(actual, Vector(target["positionsUnity"][pair.ordinal])));
                }
                result[side] = new JObject { ["baseline"] = "Exact supplied source affine matrices times actual imported inverse binds/weights; no TRS assumption or GPU approximation. Blender LBS includes its small live upperarm drivers; portable defaults are recorded separately.",
                    ["meanMeters"] = distances.Average(), ["maxMeters"] = distances.Max() };
            }
            return result;
        }
        private static JObject Compare(Mesh mesh, Transform space, JObject source)
        {
            Vector3[] points = mesh.vertices, normals = mesh.normals; var result = new JObject();
            foreach (string side in new[] { "L", "R" })
            {
                var lengths = new List<float>(); var angles = new List<float>(); JObject target = (JObject)source["stages"]["source-smooth"][side];
                int[] ids = target["portableIndices"].ToObject<int[]>();
                for (int i = 0; i < ids.Length; i++)
                {
                    lengths.Add(Vector3.Distance(space.TransformPoint(points[ids[i]]), Vector(target["positionsUnity"][i])));
                    angles.Add(Vector3.Angle(space.TransformDirection(normals[ids[i]]), Vector(target["normalsUnity"][i])));
                }
                result[side] = new JObject { ["vertices"] = ids.Length, ["positionMeanMeters"] = lengths.Average(), ["positionMaxMeters"] = lengths.Max(),
                    ["shaderNormalMeanDegrees"] = angles.Average(), ["shaderNormalMaxDegrees"] = angles.Max() };
            }
            return result;
        }
        private static int Depth(Transform t) { int value = 0; while (t.parent != null) { value++; t = t.parent; } return value; }
        private static Matrix4x4 Matrix(JToken value) { var m = new Matrix4x4(); for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) m[r, c] = (float)value[r][c]; return m; }
        private static Vector3 Vector(JToken value) => new((float)value[0], (float)value[1], (float)value[2]);
        private static void Require(bool value, string message) { if (!value) throw new InvalidDataException(message); }
    }
}
#endif

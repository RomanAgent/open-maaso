using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using Maaso.Avatar;
using UnityEditor;
using UnityEngine;
using Object = UnityEngine.Object;

/// <summary>
/// Accepts the offline Blender sampler's payload only after the real imported
/// Joy mesh and shipped VRM match its frozen identity. Never edits a VRM/blend.
/// The sampler is docs/avatar/joy_sportswear_15/bake_elbow_correctives.py.
/// </summary>
public static class MaasoJoyElbowCorrectiveBaker
{
    private const string Model = "Assets/MaasoAvatar/Models/Default/Joy.vrm";
    private const string Resource = "Assets/Resources/MaasoAvatar/joy_elbow_correctives.json";

    [Serializable] private sealed class MeshEvidence
    {
        public string fingerprint, normalFingerprint;
        public int vertexCount;
        public int[] indexCounts, boneIndices;
        public float[] positions, normals, weights;
        public string[] boneNames;
    }

    /// <summary>Read-only portable import evidence. No asset is saved or reimported.</summary>
    public static void DumpImportedMesh()
    {
        var source = AssetDatabase.LoadAssetAtPath<GameObject>(Model);
        var body = source.GetComponentsInChildren<SkinnedMeshRenderer>(true).Single(r => r.name == "Joy_body");
        string path = Environment.GetEnvironmentVariable("MAASO_JOY_ELBOW_MESH_EVIDENCE") ??
            Path.Combine(Path.GetTempPath(), "maaso-arm-jitter-20261016", "joy-imported-mesh.json");
        WriteEvidence(body, path);
    }

    /// <summary>Run without -quit: the actual production loader is awaited before batch exit.</summary>
    public static async void DumpBothImportsForBatch()
    {
        GameObject runtime = null;
        int result = 1;
        try
        {
            DumpImportedMesh();
            var instance = await MaasoVrmLoader.LoadVrm10Async(Path.GetFullPath(Model));
            if (instance == null) throw new InvalidDataException("Production VRM loader failed.");
            runtime = instance.gameObject;
            var body = runtime.GetComponentsInChildren<SkinnedMeshRenderer>(true).Single(r => r.name == "Joy_body");
            string path = Environment.GetEnvironmentVariable("MAASO_JOY_ELBOW_RUNTIME_MESH_EVIDENCE") ??
                Path.Combine(Path.GetTempPath(), "maaso-arm-jitter-20261016", "joy-runtime-imported-mesh.json");
            WriteEvidence(body, path);
            var helper = runtime.AddComponent<AvatarJoyElbowCorrectives>();
            bool bound = helper.Bind(runtime.transform);
            Debug.Log("Joy actual production loader corrective bind=" + bound + ", reason=" + helper.LastFailure);
            if (!bound) throw new InvalidDataException(helper.LastFailure);
            result = 0;
        }
        catch (Exception error) { Debug.LogException(error); }
        finally
        {
            if (runtime != null) Object.DestroyImmediate(runtime);
            if (Application.isBatchMode) EditorApplication.Exit(result);
        }
    }

    private static void WriteEvidence(SkinnedMeshRenderer body, string path)
    {
        Mesh mesh = body.sharedMesh;
        Vector3[] points = mesh.vertices, normals = mesh.normals;
        BoneWeight[] weights = mesh.boneWeights;
        var value = new MeshEvidence { fingerprint = AvatarJoyElbowCorrectives.ComputeMeshFingerprint(mesh, body.bones),
            normalFingerprint = AvatarJoyElbowCorrectives.ComputeNormalFingerprint(mesh),
            vertexCount = points.Length, indexCounts = Enumerable.Range(0, mesh.subMeshCount).Select(i => (int)mesh.GetIndexCount(i)).ToArray(),
            boneNames = body.bones.Select(bone => bone.name).ToArray(), positions = new float[points.Length * 3],
            normals = new float[points.Length * 3], boneIndices = new int[points.Length * 4], weights = new float[points.Length * 4] };
        for (int index = 0; index < points.Length; index++)
        {
            for (int axis = 0; axis < 3; axis++) { value.positions[index * 3 + axis] = points[index][axis]; value.normals[index * 3 + axis] = normals[index][axis]; }
            BoneWeight w = weights[index];
            value.boneIndices[index * 4] = w.boneIndex0; value.boneIndices[index * 4 + 1] = w.boneIndex1;
            value.boneIndices[index * 4 + 2] = w.boneIndex2; value.boneIndices[index * 4 + 3] = w.boneIndex3;
            value.weights[index * 4] = w.weight0; value.weights[index * 4 + 1] = w.weight1;
            value.weights[index * 4 + 2] = w.weight2; value.weights[index * 4 + 3] = w.weight3;
        }
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        File.WriteAllText(path, JsonUtility.ToJson(value));
        Debug.Log("Joy imported mesh evidence: " + path + ", SHA=" + value.fingerprint);
    }

    [MenuItem("Maaso/Avatar/Validate Joy Elbow Correctives")]
    public static void ValidateCheckedInProfile() => Validate(File.ReadAllText(Resource));

    /// <summary>Batch input is explicit; a successful validation is required before replacing the resource.</summary>
    public static void BakeFromSourcePayload()
    {
        string path = Environment.GetEnvironmentVariable("MAASO_JOY_ELBOW_PROFILE_JSON");
        if (string.IsNullOrWhiteSpace(path)) throw new InvalidOperationException("Set MAASO_JOY_ELBOW_PROFILE_JSON to the reviewed offline sampler output.");
        string payload = File.ReadAllText(path);
        Validate(payload);
        Directory.CreateDirectory(Path.GetDirectoryName(Resource));
        File.WriteAllText(Resource, payload);
        AssetDatabase.ImportAsset(Resource, ImportAssetOptions.ForceSynchronousImport);
        Debug.Log("Validated Joy authored elbow corrective resource updated; original VRM/blend unchanged.");
    }

    public static void Validate(string payload)
    {
        var profile = JsonUtility.FromJson<AvatarJoyElbowCorrectives.Profile>(payload);
        if (!AvatarJoyElbowCorrectives.ValidateProfile(profile)) throw new InvalidDataException("Invalid reviewed Joy corrective payload.");
        using (var sha = SHA256.Create())
        {
            string actual = BitConverter.ToString(sha.ComputeHash(File.ReadAllBytes(Model))).Replace("-", "").ToLowerInvariant();
            if (actual != profile.vrmSha256) throw new InvalidDataException("VRM asset changed; source rebake and review required.");
        }
        GameObject source = AssetDatabase.LoadAssetAtPath<GameObject>(Model);
        if (source == null) throw new InvalidDataException("Joy import unavailable.");
        GameObject instance = Object.Instantiate(source);
        try
        {
            var body = instance.GetComponentsInChildren<SkinnedMeshRenderer>(true).Single(r => r.name == profile.meshName);
            string fingerprint = AvatarJoyElbowCorrectives.ComputeMeshFingerprint(body.sharedMesh, body.bones);
            if (fingerprint != profile.meshFingerprint)
                throw new InvalidDataException("Imported Joy bind geometry/weights differ from the sampled portable model: " + fingerprint);
            if (AvatarJoyElbowCorrectives.ComputeNormalFingerprint(body.sharedMesh) != profile.normalFingerprint)
                throw new InvalidDataException("Imported Joy split normals differ from the sampled model.");
            int original = body.sharedMesh.blendShapeCount;
            string[] names = Enumerable.Range(0, original).Select(body.sharedMesh.GetBlendShapeName).ToArray();
            var helper = instance.AddComponent<AvatarJoyElbowCorrectives>();
            if (!helper.Bind(instance.transform)) throw new InvalidDataException(helper.LastFailure);
            if (!names.SequenceEqual(Enumerable.Range(0, original).Select(body.sharedMesh.GetBlendShapeName)))
                throw new InvalidDataException("Existing expression indices changed.");
            Debug.Log("Joy elbow correctives validated: vertices=" + profile.vertexCount + ", originalExpressions=" + original +
                ", appended=" + profile.arms.Sum(arm => arm.samples.Length) + ", bindSHA=" + fingerprint);
        }
        finally { Object.DestroyImmediate(instance); }
    }
}

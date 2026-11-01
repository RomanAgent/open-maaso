using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using UniVRM10;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>
    /// Joy-scoped source deformation with bounded natural elbow fairing baked
    /// from actual reviewed R80 GPU positions. This reduces sharp folds; it does
    /// not remove natural elbow creases. Sparse inverse-skinned samples become
    /// GPU blendshapes once at bind time;
    /// a frame only changes their weights. This never changes joints, original
    /// expressions, the source mesh, or its existing normals/tangents. It is not
    /// an anatomical pose limiter and does not replace the Rigify arm adapter.
    /// </summary>
    [DefaultExecutionOrder(11020)]
    public sealed class AvatarJoyElbowCorrectives : MonoBehaviour
    {
        public const string ResourcePath = "MaasoAvatar/joy_elbow_correctives";
        public const string SourceSha256 = "d2d5acb47aecf65c94d31f1b28f6cd65d06cf737a8309dab2ff07b360fd0eb87";
        public const string VrmSha256 = "39a102a5912866af033a0da7e423a85a49202630d77e3d70349431ea1f9e5f19";
        public const string NaturalizationPolicy = "elbow-taubin48-8mm/v1";
        public const string ReferenceProfileSha256 = "f61c55a9ddd7c703bbb7ff88caa9334aba48ec6239737e5f746695e7d17ad96c";
        private const string ShapePrefix = "Maaso.Joy.Elbow.";

        [Serializable] public sealed class Profile
        {
            public int schemaVersion, vertexCount;
            public string sourceSha256, vrmSha256, meshName, meshFingerprint, normalFingerprint;
            public string naturalizationPolicy, referenceProfileSha256, normalFallbackMode;
            public ArmData[] arms;
        }
        [Serializable] public sealed class ArmData
        {
            public string side;
            public int[] indices;
            public SampleData[] samples;
        }
        [Serializable] public sealed class SampleData
        {
            public float flexDegrees;
            public float[] deltaPositions, deltaNormals;
        }
        private sealed class Arm
        {
            public Transform Upper, Forearm, Hand;
            public Quaternion ForearmFromUpper;
            public float[] Knots;
            public int FirstShape;
        }

        private SkinnedMeshRenderer skin;
        private Mesh originalMesh, ownedMesh;
        private Arm[] arms;
        public bool Bound => skin != null && ownedMesh != null && skin.sharedMesh == ownedMesh;
        public string LastFailure { get; private set; }

        public bool Bind(Transform modelRoot)
        {
            Reset();
            if (modelRoot == null || modelRoot.GetComponent<Vrm10Instance>() == null)
                return Fail("Unreviewed model");
            TextAsset asset = Resources.Load<TextAsset>(ResourcePath);
            if (asset == null) return Fail("Corrective profile unavailable");
            Profile profile;
            try { profile = JsonUtility.FromJson<Profile>(asset.text); }
            catch (Exception) { return Fail("Invalid corrective profile"); }
            if (!ValidateProfile(profile)) return Fail("Unreviewed corrective profile");
            SkinnedMeshRenderer target = null;
            foreach (var renderer in modelRoot.GetComponentsInChildren<SkinnedMeshRenderer>(true))
            {
                if (renderer.name != profile.meshName) continue;
                if (target != null) return Fail("Ambiguous body renderer");
                target = renderer;
            }
            if (target == null || target.sharedMesh == null) return Fail("Body renderer unavailable");
            Mesh mesh = target.sharedMesh;
            if (mesh.vertexCount != profile.vertexCount || mesh.GetBlendShapeIndex("fix_upperarm.Z_rot.L") < 0 ||
                mesh.GetBlendShapeIndex("fix_upperarm.Z_rot.R") < 0 ||
                mesh.GetBlendShapeIndex("fix_upperarm.X_rot.L") < 0 ||
                mesh.GetBlendShapeIndex("fix_upperarm.X_rot.R") < 0)
                return Fail("Unreviewed body mesh");
            try
            {
                if (ComputeMeshFingerprint(mesh, target.bones) != profile.meshFingerprint)
                    return Fail("Body bind geometry or skin weights changed");
                if (ComputeNormalFingerprint(mesh) != profile.normalFingerprint)
                    return Fail("Body split normals changed");
            }
            catch (Exception) { return Fail("Unreadable body bind geometry"); }
            var named = new Dictionary<string, Transform>(StringComparer.Ordinal);
            foreach (Transform bone in target.bones)
            {
                if (bone == null || named.ContainsKey(bone.name)) return Fail("Ambiguous skin bones");
                named.Add(bone.name, bone);
            }
            var prepared = new Arm[2];
            Matrix4x4[] bindposes = mesh.bindposes;
            if (bindposes.Length != target.bones.Length) return Fail("Reviewed arm bind poses unavailable");
            var rest = new Dictionary<Transform, Quaternion>();
            for (int index = 0; index < bindposes.Length; index++)
            {
                Matrix4x4 matrix = bindposes[index].inverse;
                rest.Add(target.bones[index], Quaternion.LookRotation(matrix.GetColumn(2), matrix.GetColumn(1)));
            }
            for (int side = 0; side < prepared.Length; side++)
            {
                ArmData data = profile.arms[side];
                if (!named.TryGetValue("DEF-upper_arm." + data.side, out Transform upper) ||
                    !named.TryGetValue("DEF-forearm." + data.side, out Transform forearm) ||
                    !named.TryGetValue("DEF-hand." + data.side, out Transform hand))
                    return Fail("Reviewed arm joints unavailable");
                prepared[side] = new Arm { Upper = upper, Forearm = forearm, Hand = hand,
                    ForearmFromUpper = Quaternion.Inverse(rest[upper]) * rest[forearm],
                    Knots = Array.ConvertAll(data.samples, sample => sample.flexDegrees) };
            }
            Mesh clone = null;
            try
            {
                clone = Instantiate(mesh);
                clone.name = mesh.name + " (Joy authored elbow correctives)";
                for (int side = 0; side < prepared.Length; side++)
                {
                    ArmData data = profile.arms[side];
                    prepared[side].FirstShape = clone.blendShapeCount;
                    for (int knot = 0; knot < data.samples.Length; knot++)
                    {
                        string name = ShapePrefix + data.side + "." + knot;
                        if (clone.GetBlendShapeIndex(name) >= 0) throw new InvalidDataException("Correctives already applied");
                        var positions = new Vector3[mesh.vertexCount];
                        var normals = new Vector3[mesh.vertexCount];
                        SampleData sample = data.samples[knot];
                        for (int point = 0; point < data.indices.Length; point++)
                        {
                            int offset = point * 3, index = data.indices[point];
                            positions[index] = ReadVector(sample.deltaPositions, offset);
                            normals[index] = ReadVector(sample.deltaNormals, offset);
                        }
                        clone.AddBlendShapeFrame(name, 100f, positions, normals, null);
                    }
                }
                skin = target;
                originalMesh = mesh;
                ownedMesh = clone;
                arms = prepared;
                target.sharedMesh = clone;
                LastFailure = null;
                ApplyAfterVrm();
                return true;
            }
            catch (Exception)
            {
                if (clone != null) DestroyOwned(clone);
                return Fail("Unable to install corrective frames");
            }
        }

        /// <summary>Only appended GPU shape weights are written; no mesh reads or allocations per frame.</summary>
        public void ApplyAfterVrm()
        {
            if (!Bound || !isActiveAndEnabled || arms == null) return;
            foreach (Arm arm in arms)
            {
                if (arm.Upper == null || arm.Forearm == null || arm.Hand == null) { ClearWeights(); return; }
                Vector3 upper = arm.Forearm.position - arm.Upper.position;
                Vector3 forearm = arm.Hand.position - arm.Forearm.position;
                if (!Finite(upper) || !Finite(forearm) || upper.sqrMagnitude < .0001f || forearm.sqrMagnitude < .0001f)
                { ClearWeights(); return; }
                float angle = Vector3.Angle(upper, forearm);
                float influence = RollInfluence(arm.Upper.rotation, arm.Forearm.rotation, arm.ForearmFromUpper, forearm);
                SelectKnots(arm.Knots, angle, out int first, out int second, out float mix);
                for (int knot = 0; knot < arm.Knots.Length; knot++)
                {
                    float weight = knot == first ? 100f * (1f - mix) : knot == second ? 100f * mix : 0f;
                    skin.SetBlendShapeWeight(arm.FirstShape + knot, weight * influence);
                }
            }
        }

        /// <summary>
        /// The reviewed source has no relative roll in a pure elbow bend. Fade
        /// this bend-only approximation outside its validated twist domain;
        /// unsupported pronation must not become a worse authored deformation.
        /// </summary>
        public static float RollInfluence(Quaternion upper, Quaternion forearm, Quaternion restOffset, Vector3 direction)
        {
            if (!Finite(direction) || direction.sqrMagnitude < .0001f) return 0f;
            direction.Normalize();
            Quaternion reference = upper * restOffset;
            Quaternion expected = Quaternion.FromToRotation(reference * Vector3.up, direction) * reference;
            float roll = Mathf.Abs(Vector3.SignedAngle(expected * Vector3.right, forearm * Vector3.right, direction));
            return 1f - Mathf.SmoothStep(0f, 1f, Mathf.InverseLerp(35f, 70f, roll));
        }

        /// <summary>Piecewise interpolation is bounded to the reviewed sample domain.</summary>
        public static void SelectKnots(float[] knots, float angle, out int first, out int second, out float mix)
        {
            first = second = 0;
            mix = 0f;
            if (knots == null || knots.Length == 0 || !Finite(angle) || angle <= knots[0]) return;
            for (int index = 1; index < knots.Length; index++)
            {
                if (angle > knots[index]) continue;
                first = index - 1;
                second = index;
                mix = Mathf.Clamp01((angle - knots[first]) / (knots[second] - knots[first]));
                return;
            }
            first = second = knots.Length - 1;
        }

        public void Reset()
        {
            if (skin != null && ownedMesh != null && skin.sharedMesh == ownedMesh) skin.sharedMesh = originalMesh;
            if (ownedMesh != null) DestroyOwned(ownedMesh);
            skin = null;
            originalMesh = ownedMesh = null;
            arms = null;
        }

        private void ClearWeights()
        {
            if (!Bound || arms == null) return;
            foreach (Arm arm in arms)
                for (int knot = 0; knot < arm.Knots.Length; knot++) skin.SetBlendShapeWeight(arm.FirstShape + knot, 0f);
        }
        private bool Fail(string reason) { LastFailure = reason; return false; }
        private void LateUpdate() => ApplyAfterVrm();
        private void OnDisable() => ClearWeights();
        private void OnDestroy() => Reset();
        private static void DestroyOwned(Mesh mesh)
        {
            if (Application.isPlaying) Destroy(mesh);
            else DestroyImmediate(mesh);
        }
        private static Vector3 ReadVector(float[] values, int index) => new(values[index], values[index + 1], values[index + 2]);
        private static bool Finite(float value) => !float.IsNaN(value) && !float.IsInfinity(value);
        private static bool Finite(Vector3 value) => Finite(value.x) && Finite(value.y) && Finite(value.z);

        public static bool ValidateProfile(Profile value)
        {
            if (value == null || value.schemaVersion != 2 || value.naturalizationPolicy != NaturalizationPolicy ||
                value.referenceProfileSha256 != ReferenceProfileSha256 || value.normalFallbackMode != "prior-r80" ||
                value.sourceSha256 != SourceSha256 ||
                value.vrmSha256 != VrmSha256 || value.meshName != "Joy_body" || value.vertexCount != 32930 ||
                value.meshFingerprint == null || value.meshFingerprint.Length != 64 ||
                value.normalFingerprint == null || value.normalFingerprint.Length != 64 || value.arms == null || value.arms.Length != 2)
                return false;
            var used = new HashSet<int>();
            for (int side = 0; side < 2; side++)
            {
                ArmData arm = value.arms[side];
                if (arm == null || arm.side != (side == 0 ? "L" : "R") || arm.indices == null ||
                    arm.indices.Length < 500 || arm.indices.Length > 2000 || arm.samples == null || arm.samples.Length != 10) return false;
                foreach (int index in arm.indices)
                    if (index < 0 || index >= value.vertexCount || !used.Add(index)) return false;
                float prior = -1f;
                foreach (SampleData sample in arm.samples)
                {
                    int count = arm.indices.Length * 3;
                    if (sample == null || !Finite(sample.flexDegrees) || sample.flexDegrees <= prior ||
                        sample.flexDegrees < 0f || sample.flexDegrees > 150f || sample.deltaPositions == null ||
                        sample.deltaNormals == null || sample.deltaPositions.Length != count || sample.deltaNormals.Length != count) return false;
                    for (int point = 0; point < count; point += 3)
                    {
                        Vector3 position = ReadVector(sample.deltaPositions, point), normal = ReadVector(sample.deltaNormals, point);
                        if (!Finite(position) || !Finite(normal) || position.sqrMagnitude > .04f * .04f || normal.sqrMagnitude > 9f) return false;
                    }
                    prior = sample.flexDegrees;
                }
            }
            return true;
        }

        /// <summary>Strict ordered bind geometry/weights signature shared with the offline baker.</summary>
        public static string ComputeMeshFingerprint(Mesh mesh, Transform[] bones)
        {
            Vector3[] vertices = mesh.vertices;
            BoneWeight[] weights = mesh.boneWeights;
            if (vertices.Length != weights.Length) throw new InvalidDataException("Missing portable skin weights");
            using var stream = new MemoryStream();
            using (var writer = new BinaryWriter(stream, Encoding.UTF8, true))
            {
                writer.Write((uint)vertices.Length);
                writer.Write((uint)mesh.subMeshCount);
                for (int submesh = 0; submesh < mesh.subMeshCount; submesh++) writer.Write(mesh.GetIndexCount(submesh));
                for (int vertex = 0; vertex < vertices.Length; vertex++)
                {
                    Vector3 point = vertices[vertex];
                    writer.Write(Quantize(point.x, 1000000));
                    writer.Write(Quantize(point.y, 1000000));
                    writer.Write(Quantize(point.z, 1000000));
                    BoneWeight weight = weights[vertex];
                    var entries = new List<KeyValuePair<string, float>>(4);
                    void Add(int index, float amount)
                    {
                        if (amount <= .000001f) return;
                        if (index < 0 || index >= bones.Length || bones[index] == null || !Finite(amount))
                            throw new InvalidDataException("Invalid skin weights");
                        entries.Add(new KeyValuePair<string, float>(bones[index].name, amount));
                    }
                    Add(weight.boneIndex0, weight.weight0); Add(weight.boneIndex1, weight.weight1);
                    Add(weight.boneIndex2, weight.weight2); Add(weight.boneIndex3, weight.weight3);
                    entries.Sort((a, b) => StringComparer.Ordinal.Compare(a.Key, b.Key));
                    writer.Write((uint)entries.Count);
                    foreach (var entry in entries)
                    {
                        byte[] name = Encoding.UTF8.GetBytes(entry.Key);
                        writer.Write((uint)name.Length); writer.Write(name);
                        writer.Write(Quantize(entry.Value, 100000));
                    }
                }
            }
            using var sha = SHA256.Create();
            byte[] digest = sha.ComputeHash(stream.ToArray());
            return BitConverter.ToString(digest).Replace("-", "").ToLowerInvariant();
        }
        /// <summary>Normal deltas are authored against these exact imported split normals.</summary>
        public static string ComputeNormalFingerprint(Mesh mesh)
        {
            Vector3[] normals = mesh.normals;
            if (normals.Length != mesh.vertexCount) throw new InvalidDataException("Missing split normals");
            using var stream = new MemoryStream();
            using (var writer = new BinaryWriter(stream, Encoding.UTF8, true))
            {
                writer.Write((uint)normals.Length);
                foreach (Vector3 normal in normals)
                {
                    writer.Write(Quantize(normal.x, 1000000));
                    writer.Write(Quantize(normal.y, 1000000));
                    writer.Write(Quantize(normal.z, 1000000));
                }
            }
            using var sha = SHA256.Create();
            return BitConverter.ToString(sha.ComputeHash(stream.ToArray())).Replace("-", "").ToLowerInvariant();
        }

        private static int Quantize(float value, double scale)
        {
            if (!Finite(value)) throw new InvalidDataException("Non-finite mesh data");
            return checked((int)Math.Floor(value * scale + .5));
        }
    }
}

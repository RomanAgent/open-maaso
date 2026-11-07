#if UNITY_EDITOR
using System;
using System.IO;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEngine;
using UnityEngine.Rendering;

namespace Maaso.Editor
{
    /// <summary>Copies only the desk mesh with Editor read access, never making
    /// the million-triangle room readable in a player.</summary>
    public sealed class DeskWorkMeshResourceBuilder : IPreprocessBuildWithReport
    {
        public const string SourcePath = "Assets/MaasoWorld/PersonalSpace/CoastalV4/PersonalSpaceV4.fbx";
        public const string MeshPath = "Assets/MaasoWorld/Resources/MaasoDeskWorkMesh.asset";
        public const string ReceiptPath = "Assets/MaasoWorld/Resources/MaasoDeskWorkMeshReceipt.json";
        public int callbackOrder => -100;
        public void OnPreprocessBuild(BuildReport report)
        {
            var dependencies = EditorBuildSettings.scenes.Where(scene => scene.enabled)
                .SelectMany(scene => AssetDatabase.GetDependencies(scene.path, true));
            if (RequiresDeskMesh(dependencies, File.Exists(MeshPath), File.Exists(ReceiptPath)))
                Build();
            else
                Debug.Log("[DeskWorkMesh] Active scenes contain no coastal desk; no resource is generated.");
        }

        internal static bool RequiresDeskMesh(IEnumerable<string> dependencies, bool hasMesh, bool hasReceipt)
        {
            return hasMesh || hasReceipt || (dependencies ?? Enumerable.Empty<string>()).Any(path =>
                string.Equals(path, SourcePath, StringComparison.OrdinalIgnoreCase) ||
                string.Equals(path, MeshPath, StringComparison.OrdinalIgnoreCase) ||
                string.Equals(path, ReceiptPath, StringComparison.OrdinalIgnoreCase));
        }

        [Serializable]
        private sealed class Receipt
        {
            public int schema = 1;
            public string sourceSha256, sourceMeshName;
            public int vertexCount, subMeshCount;
        }

        [MenuItem("Maaso/World/Prepare Desk Work Mesh")]
        public static void Build()
        {
            var model = AssetDatabase.LoadAssetAtPath<GameObject>(SourcePath);
            if (model == null) throw new BuildFailedException("Reviewed coastal source model is missing.");
            var filters = model.GetComponentsInChildren<MeshFilter>(true)
                .Where(value => value.name == "V4_WorkDesk_Baked").ToArray();
            if (filters.Length != 1 || filters[0].sharedMesh == null)
                throw new BuildFailedException("Reviewed source desk mesh is missing or ambiguous.");
            var source = filters[0].sharedMesh;
            if (source.blendShapeCount != 0)
                throw new BuildFailedException("The source desk must remain a static mesh.");
            string fingerprint;
            using (var stream = File.OpenRead(SourcePath))
            using (var sha = SHA256.Create())
                fingerprint = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
            var existing = AssetDatabase.LoadAssetAtPath<Mesh>(MeshPath);
            Receipt receipt = null;
            if (File.Exists(ReceiptPath))
                try { receipt = JsonUtility.FromJson<Receipt>(File.ReadAllText(ReceiptPath)); } catch { }
            if (existing != null && existing.isReadable && receipt != null &&
                receipt.schema == 1 && receipt.sourceSha256 == fingerprint &&
                receipt.sourceMeshName == source.name && receipt.vertexCount == source.vertexCount &&
                receipt.subMeshCount == source.subMeshCount && existing.vertexCount == source.vertexCount &&
                existing.subMeshCount == source.subMeshCount && existing.bounds == source.bounds)
            {
                Debug.Log("[DeskWorkMesh] Current standalone readable desk resource: " + existing.vertexCount + " vertices.");
                return;
            }

            var mesh = CopyReadable(source);
            try
            {
                mesh.name = "MaasoDeskWorkMesh";
                if (existing == null) AssetDatabase.CreateAsset(mesh, MeshPath);
                else
                {
                    EditorUtility.CopySerialized(mesh, existing);
                    EditorUtility.SetDirty(existing);
                    UnityEngine.Object.DestroyImmediate(mesh);
                }
                File.WriteAllText(ReceiptPath, JsonUtility.ToJson(new Receipt {
                    sourceSha256 = fingerprint, sourceMeshName = source.name,
                    vertexCount = source.vertexCount, subMeshCount = source.subMeshCount
                }, true) + "\n");
                AssetDatabase.ImportAsset(ReceiptPath);
                AssetDatabase.SaveAssets();
                var saved = AssetDatabase.LoadAssetAtPath<Mesh>(MeshPath);
                if (saved == null || !saved.isReadable || saved.vertexCount != source.vertexCount ||
                    saved.subMeshCount != source.subMeshCount || saved.bounds != source.bounds)
                    throw new BuildFailedException("Standalone desk mesh verification failed.");
                Debug.Log("[DeskWorkMesh] Prepared " + MeshPath + "; original model readability was not modified.");
            }
            catch
            {
                if (mesh != null && !AssetDatabase.Contains(mesh)) UnityEngine.Object.DestroyImmediate(mesh);
                throw;
            }
        }

        private static Mesh CopyReadable(Mesh source)
        {
            // MeshUtility skips the runtime isReadable gate only inside Editor.
            using var read = MeshUtility.AcquireReadOnlyMeshData(source);
            var input = read[0];
            var write = Mesh.AllocateWritableMeshData(1);
            var result = new Mesh();
            bool applied = false;
            try
            {
                var output = write[0];
                output.SetVertexBufferParams(input.vertexCount, source.GetVertexAttributes());
                for (int stream = 0; stream < input.vertexBufferCount; stream++)
                    output.GetVertexData<byte>(stream).CopyFrom(input.GetVertexData<byte>(stream));
                if (input.indexFormat == IndexFormat.UInt16)
                {
                    var indices = input.GetIndexData<ushort>();
                    output.SetIndexBufferParams(indices.Length, IndexFormat.UInt16);
                    output.GetIndexData<ushort>().CopyFrom(indices);
                }
                else
                {
                    var indices = input.GetIndexData<uint>();
                    output.SetIndexBufferParams(indices.Length, IndexFormat.UInt32);
                    output.GetIndexData<uint>().CopyFrom(indices);
                }
                output.subMeshCount = input.subMeshCount;
                for (int subMesh = 0; subMesh < input.subMeshCount; subMesh++)
                    output.SetSubMesh(subMesh, input.GetSubMesh(subMesh),
                        MeshUpdateFlags.DontRecalculateBounds | MeshUpdateFlags.DontValidateIndices);
                Mesh.ApplyAndDisposeWritableMeshData(write, result,
                    MeshUpdateFlags.DontRecalculateBounds | MeshUpdateFlags.DontValidateIndices);
                applied = true;
                result.bounds = source.bounds;
                return result;
            }
            catch
            {
                if (!applied) write.Dispose();
                UnityEngine.Object.DestroyImmediate(result);
                throw;
            }
        }
    }
}
#endif

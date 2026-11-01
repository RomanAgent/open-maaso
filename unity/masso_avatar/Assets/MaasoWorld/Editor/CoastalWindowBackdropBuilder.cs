#if UNITY_EDITOR
using System.Linq;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;

namespace Maaso.World.Editor
{
    /// <summary>One continuous, inward-facing coastal panorama. The source FBX
    /// and photograph stay intact; the legacy overscanned plane is not rendered.
    /// Its edges sit behind the room walls, beyond every outward window ray.</summary>
    public static class CoastalWindowBackdropBuilder
    {
        public const string MeshPath = "Assets/MaasoWorld/Resources/CoastalWindowBackdrop.asset";
        public static readonly Vector3 Center = new(0f, 1.5f, -4f);
        public const float Radius = 48f;

        public static void Install(GameObject model)
        {
            var source = model.GetComponentsInChildren<MeshRenderer>(true)
                .Single(renderer => renderer.name == "V2_Distant_Ocean");
            var mesh = AssetDatabase.LoadAssetAtPath<Mesh>(MeshPath);
            var rebuilt = BuildMesh();
            if (mesh == null) { mesh = rebuilt; AssetDatabase.CreateAsset(mesh, MeshPath); }
            else { EditorUtility.CopySerialized(rebuilt, mesh); Object.DestroyImmediate(rebuilt); EditorUtility.SetDirty(mesh); }
            source.enabled = false;
            var backdrop = new GameObject("CoastalWindowBackdrop");
            backdrop.transform.SetParent(model.transform, false);
            backdrop.layer = source.gameObject.layer;
            backdrop.AddComponent<MeshFilter>().sharedMesh = mesh;
            var renderer = backdrop.AddComponent<MeshRenderer>();
            renderer.sharedMaterial = source.sharedMaterial;
            renderer.shadowCastingMode = ShadowCastingMode.Off;
            renderer.receiveShadows = false;
            renderer.lightProbeUsage = LightProbeUsage.Off;
            renderer.reflectionProbeUsage = ReflectionProbeUsage.Off;
        }

        private static float InversePanorama(float value, float edge, float detailScale)
        {
            float t = value * (float)System.Math.Tanh(edge / detailScale);
            return .5f * detailScale * Mathf.Log((1f + t) / (1f - t));
        }

        public static Mesh BuildMesh()
        {
            const int columns = 96, rows = 48;
            var positions = new Vector3[(columns + 1) * (rows + 1)];
            var uv = new Vector2[positions.Length];
            var triangles = new int[columns * rows * 6];
            for (int y = 0; y <= rows; y++)
            {
                float v = y / (float)rows;
                // The photographed horizon is 53.5% from the bottom. Map it
                // to eye height; no UV overscan, edge clamp or repeated tile.
                float normalized = v < .535f ? v / .535f - 1f : (v - .535f) / .465f;
                // Concentrate photographic detail around the horizon and front
                // view, while smoothly using the remaining image toward the
                // hidden dome edges. This avoids magnifying a narrow photo crop.
                float elevation = InversePanorama(normalized, 88f, 43f) * Mathf.Deg2Rad;
                for (int x = 0; x <= columns; x++)
                {
                    float u = x / (float)columns;
                    float azimuth = InversePanorama(1f - 2f * u, 135f, 52f) * Mathf.Deg2Rad;
                    int i = y * (columns + 1) + x;
                    positions[i] = Center + Radius * new Vector3(
                        Mathf.Sin(azimuth) * Mathf.Cos(elevation), Mathf.Sin(elevation),
                        -Mathf.Cos(azimuth) * Mathf.Cos(elevation));
                    uv[i] = new Vector2(u, v);
                }
            }
            int k = 0;
            for (int y = 0; y < rows; y++) for (int x = 0; x < columns; x++)
            {
                int a = y * (columns + 1) + x, b = a + 1, c = a + columns + 1, d = c + 1;
                triangles[k++] = a; triangles[k++] = c; triangles[k++] = b;
                triangles[k++] = b; triangles[k++] = c; triangles[k++] = d;
            }
            var mesh = new Mesh { name = "CoastalWindowBackdrop" };
            mesh.vertices = positions; mesh.uv = uv; mesh.triangles = triangles;
            mesh.RecalculateNormals(); mesh.RecalculateBounds();
            return mesh;
        }
    }
}
#endif

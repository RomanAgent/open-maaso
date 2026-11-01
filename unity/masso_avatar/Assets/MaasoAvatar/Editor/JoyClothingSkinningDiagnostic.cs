#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using UniVRM10;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using Object = UnityEngine.Object;

namespace Maaso.Avatar.Editor
{
    /// <summary>
    /// Reproducible two/four-influence comparison of the installed avatar and
    /// authored Humanoid poses. Explicit linear skinning avoids an Editor
    /// Camera.Render call silently reusing stale GPU bones. Not a device capture.
    /// Never saves the opened scene, changes the model, or modifies materials.
    /// </summary>
    public static class JoyClothingSkinningDiagnostic
    {
        [Serializable] private sealed class Delta
        { public string pose, mesh; public int affectedVertices; public float maximumMeters; }
        [Serializable] private sealed class Report
        {
            public string method = "Actual imported bind poses and Animator/VRM bone matrices; explicit normalized top-N linear skinning; no morphs; temporary static renders.";
            public List<Delta> deltas = new();
        }

        public static void Run()
        {
            string output = Environment.GetEnvironmentVariable("MAASO_CLOTHING_AUDIT") ?? "/tmp/maaso-joy-clothing";
            Directory.CreateDirectory(output);
            var scene = EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
            var receiver = Object.FindFirstObjectByType<UnityAvatarCommandReceiver>();
            typeof(UnityAvatarCommandReceiver).GetMethod("Awake", BindingFlags.NonPublic | BindingFlags.Instance).Invoke(receiver, null);
            Transform root = receiver.ActiveAvatarRoot;
            var animator = root.GetComponent<Animator>();
            var vrm = root.GetComponent<Vrm10Instance>();
            animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            animator.applyRootMotion = false;
            animator.Rebind();
            animator.Update(0);
            vrm.Runtime.Process();
            var renderers = root.GetComponentsInChildren<SkinnedMeshRenderer>(true);
            foreach (var renderer in Object.FindObjectsByType<Renderer>(FindObjectsInactive.Include)) renderer.forceRenderingOff = true;
            foreach (var light in Object.FindObjectsByType<Light>()) light.enabled = false;
            var lightObject = new GameObject("ClothingAuditKey");
            var key = lightObject.AddComponent<Light>();
            key.type = LightType.Directional; key.intensity = 1.1f; key.shadows = LightShadows.Soft;
            key.transform.rotation = Quaternion.Euler(40, -30, 0);
            RenderSettings.ambientMode = AmbientMode.Flat;
            RenderSettings.ambientLight = new Color(.65f, .65f, .65f);
            var cameraObject = new GameObject("ClothingAuditCamera");
            var camera = cameraObject.AddComponent<Camera>();
            camera.clearFlags = CameraClearFlags.SolidColor; camera.backgroundColor = new Color(.7f, .7f, .7f);
            camera.orthographic = true; camera.orthographicSize = .44f;
            camera.nearClipPlane = .01f; camera.farClipPlane = 10;
            var report = new Report();
            try
            {
                var poses = new[] { ("idle_shrug", 0f), ("standard_walk", .0f), ("standard_walk", .25f), ("standard_walk", .5f), ("standard_walk", .75f), ("walk_left_turn", .5f) };
                foreach (var (state, time) in poses)
                {
                    string pose = state + "_" + Mathf.RoundToInt(time * 100);
                    animator.Play(state, 0, time); animator.Update(0); vrm.Runtime.Process();
                    var current = new Dictionary<SkinnedMeshRenderer, Mesh>();
                    foreach (var source in renderers)
                    {
                        Mesh two = Skin(source, 2), four = Skin(source, 4);
                        var delta = new Delta { pose = pose, mesh = source.name };
                        Vector3[] a = two.vertices, b = four.vertices;
                        for (int v = 0; v < a.Length; v++)
                        {
                            float distance = Vector3.Distance(a[v], b[v]);
                            if (distance > .001f) delta.affectedVertices++;
                            delta.maximumMeters = Mathf.Max(delta.maximumMeters, distance);
                        }
                        report.deltas.Add(delta); Object.DestroyImmediate(two); Object.DestroyImmediate(four);
                    }
                    foreach (int count in new[] { 2, 4 })
                    {
                        var snapshots = new List<GameObject>();
                        try
                        {
                            foreach (var source in renderers)
                            {
                                var mesh = Skin(source, count); current[source] = mesh;
                                var snapshot = new GameObject(source.name + "_audit"); snapshots.Add(snapshot);
                                snapshot.AddComponent<MeshFilter>().sharedMesh = mesh;
                                var mr = snapshot.AddComponent<MeshRenderer>();
                                mr.sharedMaterials = source.sharedMaterials;
                                mr.shadowCastingMode = ShadowCastingMode.On;
                            }
                            foreach (var (view, degrees) in new[] { ("front", 0f), ("back", 180f), ("side", 90f) })
                            {
                                Vector3 target = root.TransformPoint(new Vector3(0, 1.3f, 0));
                                camera.transform.position = target + root.TransformDirection(Quaternion.Euler(0, degrees, 0) * new Vector3(0, .08f, 2));
                                camera.transform.LookAt(target);
                                Capture(camera, Path.Combine(output, pose + "_" + view + "_bone" + count + ".png"));
                            }
                        }
                        finally
                        {
                            foreach (var snapshot in snapshots) Object.DestroyImmediate(snapshot);
                            foreach (var mesh in current.Values) Object.DestroyImmediate(mesh);
                            current.Clear();
                        }
                    }
                }
                File.WriteAllText(Path.Combine(output, "skinning-deltas.json"), JsonUtility.ToJson(report, true));
            }
            finally
            {
                Object.DestroyImmediate(cameraObject); Object.DestroyImmediate(lightObject);
                EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            }
        }

        private static Mesh Skin(SkinnedMeshRenderer source, int count)
        {
            Mesh result = Object.Instantiate(source.sharedMesh);
            var vertices = result.vertices; var normals = result.normals; var tangents = result.tangents;
            var weights = source.sharedMesh.boneWeights; var binds = source.sharedMesh.bindposes;
            Matrix4x4[] matrices = source.bones.Select((bone, i) => bone.localToWorldMatrix * binds[i]).ToArray();
            for (int v = 0; v < vertices.Length; v++)
            {
                BoneWeight w = weights[v];
                var influences = new[] { (w.boneIndex0, w.weight0), (w.boneIndex1, w.weight1), (w.boneIndex2, w.weight2), (w.boneIndex3, w.weight3) }
                    .OrderByDescending(item => item.Item2).Take(count).ToArray();
                float total = influences.Sum(item => item.Item2);
                if (total <= 0) throw new InvalidOperationException("Unweighted vertex " + source.name);
                Vector3 p = Vector3.zero, n = Vector3.zero, t = Vector3.zero;
                foreach (var (index, weight) in influences)
                {
                    float factor = weight / total;
                    p += matrices[index].MultiplyPoint3x4(vertices[v]) * factor;
                    n += matrices[index].MultiplyVector(normals[v]) * factor;
                    if (tangents.Length != 0) t += matrices[index].MultiplyVector(tangents[v]) * factor;
                }
                vertices[v] = p; normals[v] = n.normalized;
                if (tangents.Length != 0) tangents[v] = new Vector4(t.x, t.y, t.z, tangents[v].w);
            }
            result.vertices = vertices; result.normals = normals; result.tangents = tangents;
            result.RecalculateBounds(); return result;
        }

        private static void Capture(Camera camera, string path)
        {
            var rt = new RenderTexture(800, 800, 24) { antiAliasing = 4 };
            var pixels = new Texture2D(800, 800, TextureFormat.RGB24, false);
            var active = RenderTexture.active;
            try
            {
                rt.Create(); camera.targetTexture = rt; camera.Render(); RenderTexture.active = rt;
                pixels.ReadPixels(new Rect(0, 0, 800, 800), 0, 0); pixels.Apply(); File.WriteAllBytes(path, pixels.EncodeToPNG());
            }
            finally
            { camera.targetTexture = null; RenderTexture.active = active; rt.Release(); Object.DestroyImmediate(rt); Object.DestroyImmediate(pixels); }
        }
    }
}
#endif

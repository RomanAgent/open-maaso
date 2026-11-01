#if UNITY_EDITOR
using System;
using System.IO;
using System.Linq;
using Maaso.World;
using Maaso.World.Editor;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Profiling;
using UnityEngine.SceneManagement;
using Object = UnityEngine.Object;

namespace Maaso.Avatar.Editor
{
    public static class CoastalWindowAtmosphereDiagnostics
    {
        // Update only the three shared cloud assets. The published room prefabs
        // retain their existing mesh/material GUIDs and do not need rebuilding.
        public static void PublishCloudAssets()
        {
            var fixture = new GameObject("CloudAssetPublishFixture");
            try
            {
                var atmosphere = fixture.AddComponent<CoastalWindowAtmosphere>();
                CoastalCloudMeshBuilder.Install(atmosphere);
                AssetDatabase.SaveAssetIfDirty(atmosphere.CloudMesh);
                AssetDatabase.SaveAssetIfDirty(atmosphere.CloudMaterial);
                AssetDatabase.SaveAssetIfDirty(AssetDatabase.LoadAssetAtPath<Texture3D>(CoastalCloudMeshBuilder.DensityPath));
            }
            finally { Object.DestroyImmediate(fixture); }
        }

        public static void PublishAndCapture()
        {
            PublishCloudAssets();
            CapturePublished();
        }

        // A separate fresh-Editor entry point verifies that the saved,
        // non-readable texture survives reload without another density bake.
        public static void CapturePublished()
        {
            string output = Environment.GetEnvironmentVariable("MAASO_ROOM_CAPTURE_OUTPUT");
            if (string.IsNullOrEmpty(output))
                throw new InvalidOperationException("Set MAASO_ROOM_CAPTURE_OUTPUT to an evidence directory.");
            for (int i = 0; i < SceneManager.sceneCount; i++)
            {
                var open = SceneManager.GetSceneAt(i);
                if (open.isDirty && !(string.IsNullOrEmpty(open.path) && open.rootCount == 0))
                    throw new InvalidOperationException("Save open scenes before running cloud diagnostics.");
            }
            Directory.CreateDirectory(output);
            var originalSetup = EditorSceneManager.GetSceneManagerSetup();
            float originalNightBlend = Shader.GetGlobalFloat("_MaasoWorldNightBlend");
            GameObject room = null;
            RenderTexture target = null;
            Camera camera = null;
            try
            {
                const string scenePath = "Assets/MaasoAvatar/Scenes/Companion.unity";
                var scene = EditorSceneManager.OpenScene(scenePath, OpenSceneMode.Single);
                camera = scene.GetRootGameObjects().SelectMany(r => r.GetComponentsInChildren<Camera>(true))
                    .Single(c => c.CompareTag("MainCamera"));
                room = Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));
                var map = room.GetComponent<PersistentWorldMapController>();
                PersonalSpaceSceneBuilder.PrepareRuntimePortrait(camera, map);
                camera.GetComponent<FrontFullBodyCamera>().enabled = false;
                camera.rect = new Rect(0, 0, 1, 1);
                camera.cullingMask = ~0;
                camera.nearClipPlane = .02f;
                camera.farClipPlane = 160;
                camera.fieldOfView = 70;
                camera.aspect = .5625f;
                var atmosphere = room.GetComponentInChildren<CoastalWindowAtmosphere>(true);
                var ocean = room.GetComponentsInChildren<MeshRenderer>(true).Single(r => r.name == "V2_Distant_Ocean");
                var texture = (Texture2D)ocean.sharedMaterial.GetTexture("_EmissionMap");
                target = new RenderTexture(900, 1600, 24) { antiAliasing = 4 };
                target.Create();
                camera.targetTexture = target;
                var actor = camera.GetComponent<UnityAvatarCommandReceiver>().ActiveAvatarRoot;
                var oldPosition = actor.position;
                var oldRotation = actor.rotation;
                var captures = new JArray();
                float seconds = 0;
                void Present(float time) { seconds = time; atmosphere.PresentAt(time); }
                void Save(string name, Vector3 position, Vector3 look)
                {
                    camera.transform.SetPositionAndRotation(position, Quaternion.LookRotation(look - position, Vector3.up));
                    camera.Render();
                    RenderTexture.active = target;
                    var image = new Texture2D(900, 1600, TextureFormat.RGB24, false);
                    try
                    {
                        image.ReadPixels(new Rect(0, 0, 900, 1600), 0, 0);
                        image.Apply();
                        File.WriteAllBytes(Path.Combine(output, name + ".png"), image.EncodeToPNG());
                    }
                    finally { Object.DestroyImmediate(image); }
                    captures.Add(new JObject
                    {
                        ["file"] = name + ".png", ["simulationSeconds"] = seconds,
                        ["position"] = new JArray(position.x, position.y, position.z),
                        ["lookAt"] = new JArray(look.x, look.y, look.z),
                        ["fieldOfView"] = camera.fieldOfView,
                        ["cloudRaySteps"] = atmosphere.transform.Find("CoastalCloudVolumes")
                            .GetComponentInChildren<MeshRenderer>().sharedMaterial.GetFloat("_StepCount"),
                        ["nightBlend"] = Shader.GetGlobalFloat("_MaasoWorldNightBlend")
                    });
                }

                Shader.SetGlobalFloat("_MaasoWorldNightBlend", 0f);
                actor.position = new Vector3(0, 0, -3.1f);
                actor.rotation = Quaternion.Euler(0, 180, 0);
                Present(0);
                Save("window-right-after", new Vector3(2.35f, 1.65f, -3.05f), new Vector3(-5, 2.15f, -10));
                Save("window-left-after", new Vector3(-2.35f, 1.65f, -3.05f), new Vector3(5, 2.15f, -10));
                var front = new Vector3(1.15f, 1.7f, -1.8f);
                var frontLook = new Vector3(0, 1.85f, -7);
                Save("window-front-time0", front, frontLook);
                Present(16);
                Save("window-front-time16", front, frontLook);
                var cloudRenderers = atmosphere.transform.Find("CoastalCloudVolumes").GetComponentsInChildren<MeshRenderer>();
                foreach (var renderer in cloudRenderers) renderer.enabled = false;
                Save("window-front-clouds-disabled", front, frontLook);
                foreach (var renderer in cloudRenderers) renderer.enabled = true;
                actor.position = new Vector3(0, 0, -3.65f);
                actor.rotation = Quaternion.Euler(0, 180, 0);
                Save("window-avatar-near", new Vector3(-1.5f, 1.7f, -1.7f), new Vector3(0, 1.35f, -3.65f));
                Save("window-sky-up", new Vector3(0, 1.65f, -3.9f), new Vector3(0, 12f, -15f));

                var center = cloudRenderers[0].bounds.center;
                Save("cloud-volume-front", center + new Vector3(0, 0, 15), center);
                Save("cloud-volume-left", center + new Vector3(-12, 1, 12), center);
                Save("cloud-volume-right", center + new Vector3(12, 1, 12), center);
                // Compare integration counts without dirtying the shipped
                // material or changing density, camera, cloud time or lighting.
                var originalMaterials = cloudRenderers.Select(renderer => renderer.sharedMaterial).ToArray();
                var comparisonMaterial = new Material(atmosphere.CloudMaterial);
                try
                {
                    foreach (var renderer in cloudRenderers) renderer.sharedMaterial = comparisonMaterial;
                    foreach (int steps in new[] { 48, 56 })
                    {
                        comparisonMaterial.SetFloat("_StepCount", steps);
                        Save("window-front-steps" + steps, front, frontLook);
                        Save("cloud-volume-front-steps" + steps, center + new Vector3(0, 0, 15), center);
                    }
                }
                finally
                {
                    for (int i = 0; i < cloudRenderers.Length; i++) cloudRenderers[i].sharedMaterial = originalMaterials[i];
                    Object.DestroyImmediate(comparisonMaterial);
                }
                Shader.SetGlobalFloat("_MaasoWorldNightBlend", 1f);
                Save("window-night-material-stress", front, frontLook);
                Shader.SetGlobalFloat("_MaasoWorldNightBlend", 0f);
                actor.position = oldPosition;
                actor.rotation = oldRotation;
                room.GetComponentInChildren<LoginDoorwayRig>(true)?.TrySetSceneDoorOpen(0f);
                Save("entry-closed-after", new Vector3(2.5f, 1.6f, 1.8f), new Vector3(2.5f, 1.2f, 4.1f));

                camera.transform.SetPositionAndRotation(front, Quaternion.LookRotation(frontLook - front, Vector3.up));
                var report = DescribeCloudResources(atmosphere);
                report["oceanWrapU"] = texture.wrapModeU.ToString();
                report["oceanWrapV"] = texture.wrapModeV.ToString();
                report["sameCameraMotionFramesSeconds"] = new JArray(0, 16);
                report["captureWidth"] = target.width;
                report["captureHeight"] = target.height;
                report["captureMsaa"] = target.antiAliasing;
                report["captures"] = captures;
                report["renderCpuSubmissionTiming"] = MeasureCameraSubmission(camera, cloudRenderers);
                report["limits"] = "Real Unity Editor Camera.Render captures at explicitly sampled cloud times; not iPhone screenshots. " +
                    "Night stress only exercises the existing global material blend, not a newly implemented night environment. " +
                    "CPU submission timings are descriptive Editor measurements and do not measure iPhone GPU frame cost.";
                File.WriteAllText(Path.Combine(output, "scene-report.json"), report.ToString());
                if (ShaderUtil.ShaderHasError(atmosphere.CloudMaterial.shader))
                    throw new InvalidOperationException("Cloud shader reported compilation errors; inspect scene-report.json.");
            }
            finally
            {
                Shader.SetGlobalFloat("_MaasoWorldNightBlend", originalNightBlend);
                if (camera != null) camera.targetTexture = null;
                RenderTexture.active = null;
                if (target != null) { target.Release(); Object.DestroyImmediate(target); }
                if (room != null) Object.DestroyImmediate(room);
                if (originalSetup.Length > 0) EditorSceneManager.RestoreSceneManagerSetup(originalSetup);
                else EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            }
        }

        private static JObject DescribeCloudResources(CoastalWindowAtmosphere atmosphere)
        {
            var material = atmosphere.CloudMaterial;
            var density = material.GetTexture("_DensityVolume") as Texture3D;
            var renderers = atmosphere.transform.Find("CoastalCloudVolumes").GetComponentsInChildren<MeshRenderer>();
            if (density == null) throw new InvalidOperationException("Cloud material has no 3D density volume.");
            return new JObject
            {
                ["unityVersion"] = Application.unityVersion,
                ["graphicsApi"] = SystemInfo.graphicsDeviceType.ToString(),
                ["graphicsDevice"] = SystemInfo.graphicsDeviceName,
                ["cloudCount"] = atmosphere.CloudCount,
                ["cloudVertices"] = atmosphere.CloudMesh.vertexCount,
                ["cloudTriangles"] = atmosphere.CloudMesh.triangles.Length / 3,
                ["sharedMeshCount"] = renderers.Select(r => r.GetComponent<MeshFilter>().sharedMesh).Distinct().Count(),
                ["sharedMaterialCount"] = renderers.Select(r => r.sharedMaterial).Distinct().Count(),
                ["density"] = new JObject
                {
                    ["path"] = AssetDatabase.GetAssetPath(density),
                    ["dimensions"] = new JArray(density.width, density.height, density.depth),
                    ["format"] = density.format.ToString(), ["graphicsFormat"] = density.graphicsFormat.ToString(),
                    ["isReadable"] = density.isReadable, ["mipCount"] = density.mipmapCount,
                    ["wrap"] = density.wrapMode.ToString(), ["filter"] = density.filterMode.ToString(),
                    ["rgbaTexelBytes"] = density.width * density.height * density.depth * 4,
                    ["editorRuntimeMemoryBytes"] = Profiler.GetRuntimeMemorySizeLong(density)
                },
                ["shader"] = new JObject
                {
                    ["name"] = material.shader.name, ["supportedOnCaptureDevice"] = material.shader.isSupported,
                    ["hasError"] = ShaderUtil.ShaderHasError(material.shader),
                    ["configuredSteps"] = material.GetFloat("_StepCount"),
                    ["extinction"] = material.GetFloat("_Extinction"),
                    ["messages"] = new JArray(ShaderUtil.GetShaderMessages(material.shader).Select(message => new JObject
                    { ["severity"] = message.severity.ToString(), ["message"] = message.message }))
                }
            };
        }

        private static JObject MeasureCameraSubmission(Camera camera, MeshRenderer[] clouds)
        {
            const int samples = 12;
            var withClouds = new double[samples];
            var withoutClouds = new double[samples];
            try
            {
                for (int warmup = 0; warmup < 4; warmup++) camera.Render();
                for (int sample = 0; sample < samples; sample++)
                {
                    // Alternate order so shader warmup and accumulating driver
                    // work do not always favor the same configuration.
                    for (int pass = 0; pass < 2; pass++)
                    {
                        bool enabled = (sample + pass) % 2 == 0;
                        foreach (var cloud in clouds) cloud.enabled = enabled;
                        var timer = System.Diagnostics.Stopwatch.StartNew();
                        camera.Render();
                        timer.Stop();
                        (enabled ? withClouds : withoutClouds)[sample] = timer.Elapsed.TotalMilliseconds;
                    }
                }
            }
            finally { foreach (var cloud in clouds) cloud.enabled = true; }
            JObject Series(double[] values)
            {
                var sorted = values.OrderBy(value => value).ToArray();
                return new JObject
                {
                    ["samplesMilliseconds"] = new JArray(values),
                    ["medianMilliseconds"] = (sorted[samples / 2 - 1] + sorted[samples / 2]) * .5,
                    ["maxMilliseconds"] = sorted[samples - 1]
                };
            }
            return new JObject
            {
                ["method"] = "Stopwatch around Camera.Render only; no forced GPU completion, readback, image encoding or app UI.",
                ["withClouds"] = Series(withClouds), ["withoutClouds"] = Series(withoutClouds)
            };
        }
    }
}
#endif

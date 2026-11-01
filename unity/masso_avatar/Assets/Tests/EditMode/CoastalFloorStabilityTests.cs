using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using Newtonsoft.Json.Linq;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;
using UnityEngine.TestTools;
using Object = UnityEngine.Object;

/// <summary>Opt-in evidence from the real floor, without changing imported assets.</summary>
public sealed class CoastalFloorStabilityTests
{
    private const string Output = "/private/tmp/maaso-floor-flicker-20261017";
    private static readonly Vector2[] Offsets =
    {
        Vector2.zero, new(.0005f, .005f), new(.001f, .01f), new(.0005f, .005f),
        Vector2.zero, new(-.0005f, -.005f), new(-.001f, -.01f), Vector2.zero
    };
    private const string RuntimeSceneSetupKey = "Maaso.CoastalFloorStabilityTests.SceneSetup";

    [UnityTest]
    public IEnumerator HomeRuntimeReportsIdleFloorAndCameraState()
    {
        // SessionState survives the domain reload at the Play Mode boundary.
        // Refuse to discard unsaved user scenes when run interactively.
        if (!Application.isPlaying)
        {
            var setup = new JArray();
            for (int i = 0; i < SceneManager.sceneCount; i++)
            {
                Scene open = SceneManager.GetSceneAt(i);
                Assert.That(!open.isDirty || (string.IsNullOrEmpty(open.path) && open.rootCount == 0), Is.True,
                    "Run this diagnostic with saved scenes; it never saves or discards unsaved user changes.");
                if (!string.IsNullOrEmpty(open.path)) setup.Add(new JObject
                { ["path"] = open.path, ["isLoaded"] = open.isLoaded, ["isActive"] = open == SceneManager.GetActiveScene() });
            }
            SessionState.SetString(RuntimeSceneSetupKey, setup.ToString());
            EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
        }
        yield return new EnterPlayMode();
        Camera camera = null;
        Renderer floor = null;
        Component receiver = null;
        for (int frame = 0; frame < 300; frame++)
        {
            camera = Camera.main;
            receiver = Object.FindAnyObjectByType(RuntimeAvatarType("UnityAvatarCommandReceiver")) as Component;
            floor = Object.FindObjectsByType<Renderer>(FindObjectsInactive.Include, FindObjectsSortMode.None)
                .FirstOrDefault(value => value.name == "V4_Floor_Baked" && value.enabled && value.gameObject.activeInHierarchy);
            if (camera != null && floor != null && receiver != null) break;
            yield return null;
        }
        Assert.That(camera, Is.Not.Null, "The real Companion scene must start its Main Camera.");
        Assert.That(receiver, Is.Not.Null);
        Assert.That(floor, Is.Not.Null, "The runtime bootstrap must load and expose the real V4 floor.");
        Directory.CreateDirectory(Output);
        using (var capture = new RuntimeCapture(camera, floor))
        {
            // Flutter normally reveals the account-owned avatar. Use that
            // public command once so the real idle body and shadows exist.
            receiver.GetType().GetMethod("OnFlutterCommand").Invoke(receiver, new object[]
            {
                new JObject { ["method"] = "setLocalAvatarVisible", ["json"] = new JObject { ["visible"] = true }.ToString() }.ToString()
            });
            float warmupRealtime = Time.realtimeSinceStartup, warmupGameTime = Time.unscaledTime;
            while (Time.realtimeSinceStartup - warmupRealtime < 5f || Time.unscaledTime - warmupGameTime < 5f)
                yield return null;
            Transform revealedAvatar = RuntimeProperty(receiver, "ActiveAvatarRoot") as Transform;
            Assert.That(revealedAvatar, Is.Not.Null);
            Assert.That(revealedAvatar.GetComponentsInChildren<Renderer>().Any(renderer => renderer.enabled && !renderer.forceRenderingOff), Is.True,
                "The public visibility command must expose the real default avatar before Home camera sampling.");
            Behaviour framing = camera.GetComponent(RuntimeAvatarType("FrontFullBodyCamera")) as Behaviour;
            Behaviour portrait = camera.GetComponent(RuntimeAvatarType("PortraitDepthOfField")) as Behaviour;
            bool originalFraming = framing != null && framing.enabled, originalPortrait = portrait != null && portrait.enabled;
            var report = new JObject
            {
                ["purpose"] = "Actual Companion Play Mode, no input after initial avatar visibility command; descriptive evidence without failure thresholds.",
                ["limits"] = "Editor runtime and an explicit 360x780 camera target; not iOS native-view composition. Phases run sequentially while idle animation continues. The bottom-corner ROI can include scene objects; inspect PNGs before calling it floor-only.",
                ["initialization"] = "Default scene avatar revealed through public setLocalAvatarVisible; no pose, framing or animation commands.",
                ["warmupRealtimeSeconds"] = Time.realtimeSinceStartup - warmupRealtime,
                ["warmupUnscaledGameSeconds"] = Time.unscaledTime - warmupGameTime,
                ["minimumSampleIntervalSeconds"] = 1f / 30f,
                ["width"] = 360, ["height"] = 780, ["depthBits"] = capture.Target.depth,
                ["graphicsDevice"] = SystemInfo.graphicsDeviceName, ["graphicsApi"] = SystemInfo.graphicsDeviceType.ToString(),
                ["phases"] = new JArray()
            };
            bool[] roi = Enumerable.Range(0, 360 * 780).Select(index =>
                index / 360 >= 30 && index / 360 < 235 && (index % 360 < 72 || index % 360 >= 288)).ToArray();
            try
            {
                foreach (string phase in new[] { "baseline", "shadow_receive_off", "portrait_off", "shadow_and_portrait_off", "framing_off", "framing_off_shadow_off", "framing_off_portrait_off", "frozen_camera_no_shadow_no_portrait" })
                {
                    bool noShadow = phase is "shadow_receive_off" or "shadow_and_portrait_off" or "framing_off_shadow_off" or "frozen_camera_no_shadow_no_portrait";
                    bool noPortrait = phase is "portrait_off" or "shadow_and_portrait_off" or "framing_off_portrait_off" or "frozen_camera_no_shadow_no_portrait";
                    bool noFraming = phase is "framing_off" or "framing_off_shadow_off" or "framing_off_portrait_off" or "frozen_camera_no_shadow_no_portrait";
                    if (framing != null) framing.enabled = originalFraming && !noFraming;
                    if (portrait != null) portrait.enabled = originalPortrait && !noPortrait;
                    capture.SetShadowReception(noShadow);
                    Vector3 heldPosition = camera.transform.position;
                    Quaternion heldRotation = camera.transform.rotation;
                    float heldFov = camera.fieldOfView;
                    var frames = new JArray();
                    var deltas = new JArray();
                    Color32[] previous = null;
                    for (int frame = 0; frame < 24; frame++)
                    {
                        yield return new WaitForSecondsRealtime(1f / 30f);
                        JObject natural = RuntimeFrameState(camera, floor, receiver, portrait);
                        if (phase == "frozen_camera_no_shadow_no_portrait")
                        {
                            camera.transform.SetPositionAndRotation(heldPosition, heldRotation);
                            camera.fieldOfView = heldFov;
                        }
                        Color32[] pixels = capture.Capture(frame == 0 || frame == 23
                            ? Path.Combine(Output, $"runtime-{phase}-{frame}.png") : null);
                        JObject state = RuntimeFrameState(camera, floor, receiver, portrait);
                        state["beforeExplicitRender"] = natural;
                        frames.Add(state);
                        if (previous != null) deltas.Add(Delta(previous, pixels, roi, frame));
                        previous = pixels;
                    }
                    ((JArray)report["phases"]).Add(new JObject
                    { ["name"] = phase, ["frames"] = frames, ["bottomCornerRoiConsecutiveDeltas"] = deltas });
                    File.WriteAllText(Path.Combine(Output, "floor-runtime-home.json"), report.ToString());
                    TestContext.Out.WriteLine($"Runtime {phase}: bottom-corner RGB8 delta={AverageDelta(deltas):F6}; camera/projection/focus/material states recorded.");
                }
            }
            finally
            {
                if (portrait != null) portrait.enabled = originalPortrait;
                if (framing != null) framing.enabled = originalFraming;
            }
        }
        yield return new ExitPlayMode();
    }

    [UnityTearDown]
    public IEnumerator RestoreRuntimeDiagnosticScene()
    {
        string saved = SessionState.GetString(RuntimeSceneSetupKey, "");
        if (string.IsNullOrEmpty(saved)) yield break;
        if (Application.isPlaying) yield return new ExitPlayMode();
        saved = SessionState.GetString(RuntimeSceneSetupKey, "");
        SessionState.EraseString(RuntimeSceneSetupKey);
        SceneSetup[] setup = JArray.Parse(saved).Select(value => new SceneSetup
        { path = (string)value["path"], isLoaded = (bool)value["isLoaded"], isActive = (bool)value["isActive"] }).ToArray();
        if (setup.Length > 0) EditorSceneManager.RestoreSceneManagerSetup(setup);
        else EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
    }

    private static Type RuntimeAvatarType(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    private static object RuntimeProperty(object target, string name) => target?.GetType().GetProperty(name)?.GetValue(target);
    private static object RuntimeField(object target, string name) => target?.GetType()
        .GetField(name, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)?.GetValue(target);
    private static JToken RuntimeFieldValue(object target, string name) =>
        RuntimeField(target, name) is object value ? JToken.FromObject(value) : JValue.CreateNull();
    private static JToken RuntimeObjectIdentity(Object value) => value == null ? JValue.CreateNull() : new JObject
        { ["name"] = value.name, ["entity"] = value.GetEntityId().ToString() };
    private static JArray VectorValues(Vector3 value) => new(value.x, value.y, value.z);
    private static JArray MatrixValues(Matrix4x4 value) => new(Enumerable.Range(0, 16).Select(index => value[index]));

    private static JObject RuntimeFrameState(Camera camera, Renderer floor, Component receiver, Behaviour portrait)
    {
        Transform avatar = RuntimeProperty(receiver, "ActiveAvatarRoot") as Transform;
        Component framing = camera.GetComponent(RuntimeAvatarType("FrontFullBodyCamera"));
        Transform cachedRoot = RuntimeField(framing, "cachedBoundsRoot") as Transform;
        Transform framingRoot = RuntimeField(framing, "targetRoot") as Transform;
        Bounds cachedLocal = RuntimeField(framing, "cachedLocalBounds") is Bounds value ? value : default;
        Animator animator = avatar != null ? avatar.GetComponentInChildren<Animator>() : null;
        Bounds bounds = default;
        if (avatar != null)
            foreach (Renderer renderer in avatar.GetComponentsInChildren<Renderer>())
                if (bounds.size == Vector3.zero) bounds = renderer.bounds; else bounds.Encapsulate(renderer.bounds);
        return new JObject
        {
            ["frame"] = Time.frameCount, ["time"] = Time.time, ["unscaledTime"] = Time.unscaledTime, ["realtime"] = Time.realtimeSinceStartup,
            ["cameraPosition"] = VectorValues(camera.transform.position), ["cameraEuler"] = VectorValues(camera.transform.eulerAngles),
            ["cameraProjection"] = MatrixValues(camera.projectionMatrix), ["cameraView"] = MatrixValues(camera.worldToCameraMatrix),
            ["fov"] = camera.fieldOfView, ["aspect"] = camera.aspect,
            ["pixelRect"] = new JArray(camera.pixelRect.x, camera.pixelRect.y, camera.pixelRect.width, camera.pixelRect.height),
            ["screen"] = new JArray(Screen.width, Screen.height),
            ["dynamicResolutionScale"] = new JArray(ScalableBufferManager.widthScaleFactor, ScalableBufferManager.heightScaleFactor),
            ["framingEnabled"] = (camera.GetComponent(RuntimeAvatarType("FrontFullBodyCamera")) as Behaviour)?.enabled,
            ["framingCache"] = new JObject
            {
                ["furniturePoseActive"] = RuntimeFieldValue(framing, "furniturePoseActive"),
                ["hasCachedLocalBounds"] = RuntimeFieldValue(framing, "hasCachedLocalBounds"),
                ["cachedBoundsRoot"] = RuntimeObjectIdentity(cachedRoot),
                ["cachedLocalBoundsCenter"] = VectorValues(cachedLocal.center),
                ["cachedLocalBoundsSize"] = VectorValues(cachedLocal.size),
                ["targetRoot"] = RuntimeObjectIdentity(framingRoot),
                ["targetLocalToWorld"] = framingRoot != null ? MatrixValues(framingRoot.localToWorldMatrix) : JValue.CreateNull(),
                ["entryRoutedAvatar"] = RuntimeObjectIdentity(RuntimeField(framing, "entryRoutedAvatar") as Object),
                ["doorwayHandoffAvatar"] = RuntimeObjectIdentity(RuntimeField(framing, "doorwayHandoffAvatar") as Object),
                ["framingMode"] = JToken.FromObject(RuntimeProperty(framing, "FramingMode") ?? "missing"),
                ["transitionActive"] = RuntimeFieldValue(framing, "transitionActive"),
                ["visibleBodyRatio"] = RuntimeFieldValue(framing, "visibleBodyRatio"),
                ["hasAuthoredHomeFieldOfView"] = RuntimeFieldValue(framing, "hasAuthoredHomeFieldOfView"),
                ["authoredHomeFieldOfView"] = RuntimeFieldValue(framing, "authoredHomeFieldOfView"),
                ["homeFieldOfViewAdjusted"] = RuntimeFieldValue(framing, "homeFieldOfViewAdjusted")
            },
            ["portraitEnabled"] = portrait != null && portrait.enabled,
            ["portraitCanRender"] = JToken.FromObject(RuntimeProperty(portrait, "CanRender") ?? false),
            ["focusDistance"] = JToken.FromObject(RuntimeProperty(portrait, "FocusDistance") ?? 0f),
            ["backgroundStartDistance"] = JToken.FromObject(RuntimeProperty(portrait, "BackgroundStartDistance") ?? 0f),
            ["avatarName"] = avatar != null ? avatar.name : "missing",
            ["avatarVisibleRendererCount"] = avatar != null ? avatar.GetComponentsInChildren<Renderer>().Count(renderer => renderer.enabled && !renderer.forceRenderingOff) : 0,
            ["avatarPosition"] = VectorValues(avatar != null ? avatar.position : Vector3.zero),
            ["avatarBoundsCenter"] = VectorValues(bounds.center), ["avatarBoundsSize"] = VectorValues(bounds.size),
            ["animatorState"] = animator != null && animator.runtimeAnimatorController != null ? animator.GetCurrentAnimatorStateInfo(0).fullPathHash : 0,
            ["animatorNormalizedTime"] = animator != null && animator.runtimeAnimatorController != null ? animator.GetCurrentAnimatorStateInfo(0).normalizedTime : 0f,
            ["floorEnabled"] = floor.enabled, ["floorMatrix"] = MatrixValues(floor.localToWorldMatrix),
            ["floorReceiveShadows"] = floor.receiveShadows,
            ["materials"] = new JArray(floor.sharedMaterials.Select(material => new JObject
            {
                ["instance"] = material.GetEntityId().ToString(), ["shader"] = material.shader.name,
                ["shadowStrength"] = material.HasProperty("_DynamicShadowStrength") ? material.GetFloat("_DynamicShadowStrength") : -1,
                ["cutawayOpacity"] = material.HasProperty("_OcclusionOpacity") ? material.GetFloat("_OcclusionOpacity") : -1
            })),
            ["lights"] = new JArray(Object.FindObjectsByType<Light>(FindObjectsSortMode.None).Select(light => new JObject
            { ["name"] = light.name, ["enabled"] = light.enabled, ["rotation"] = VectorValues(light.transform.eulerAngles),
                ["intensity"] = light.intensity, ["shadowStrength"] = light.shadowStrength, ["shadows"] = light.shadows.ToString() }))
        };
    }

    private sealed class RuntimeCapture : IDisposable
    {
        public readonly RenderTexture Target;
        private readonly Camera camera;
        private readonly Renderer floor;
        private readonly RenderTexture originalTarget;
        private readonly float originalAspect;
        private readonly Material[] originalMaterials, temporaryMaterials;
        private readonly float[] originalShadowStrengths;
        private readonly Texture2D image;
        public RuntimeCapture(Camera camera, Renderer floor)
        {
            this.camera = camera; this.floor = floor;
            originalTarget = camera.targetTexture; originalAspect = camera.aspect;
            originalMaterials = floor.sharedMaterials;
            temporaryMaterials = originalMaterials.Select(material => new Material(material)).ToArray();
            originalShadowStrengths = temporaryMaterials.Select(material => material.HasProperty("_DynamicShadowStrength") ? material.GetFloat("_DynamicShadowStrength") : 0).ToArray();
            floor.sharedMaterials = temporaryMaterials;
            Target = new RenderTexture(360, 780, 24, RenderTextureFormat.ARGB32, RenderTextureReadWrite.sRGB) { antiAliasing = 1 };
            Target.Create();
            image = new Texture2D(360, 780, TextureFormat.RGB24, false, false);
            camera.targetTexture = Target;
            camera.aspect = 360f / 780;
        }
        public void SetShadowReception(bool disabled)
        {
            for (int i = 0; i < temporaryMaterials.Length; i++)
                if (temporaryMaterials[i].HasProperty("_DynamicShadowStrength"))
                    temporaryMaterials[i].SetFloat("_DynamicShadowStrength", disabled ? 0 : originalShadowStrengths[i]);
        }
        public Color32[] Capture(string png)
        {
            RenderTexture active = RenderTexture.active;
            try
            {
                camera.Render();
                RenderTexture.active = Target;
                image.ReadPixels(new Rect(0, 0, 360, 780), 0, 0); image.Apply(false, false);
                if (png != null) File.WriteAllBytes(png, image.EncodeToPNG());
                return image.GetPixels32();
            }
            finally { RenderTexture.active = active; }
        }
        public void Dispose()
        {
            if (camera != null) { camera.targetTexture = originalTarget; camera.aspect = originalAspect; }
            if (floor != null) floor.sharedMaterials = originalMaterials;
            Target.Release(); Object.DestroyImmediate(Target); Object.DestroyImmediate(image);
            foreach (Material material in temporaryMaterials) Object.DestroyImmediate(material);
        }
    }

    [UnityTest]
    public IEnumerator PublishedFloorReportsFixedCameraAndSubpixelMotionAtPhoneResolutions()
    {
        Directory.CreateDirectory(Output);
        foreach (Vector2Int size in new[] { new Vector2Int(360, 780), new Vector2Int(540, 1170) })
        {
            using var fixture = new Fixture(size.x, size.y);
            string prefix = $"{size.x}x{size.y}";
            var report = new JObject
            {
                ["purpose"] = "Descriptive Editor GPU diagnostic; no image-delta failure threshold.",
                ["limits"] = "Isolated floor only: no avatar, runtime camera controllers, dynamic shadow casters or post effects. Editor updates are not iOS runtime frames. Motion deltas include legitimate reprojection and texture gradients.",
                ["width"] = size.x, ["height"] = size.y, ["depthBits"] = fixture.Target.depth,
                ["msaa"] = fixture.Target.antiAliasing,
                ["graphicsDevice"] = SystemInfo.graphicsDeviceName,
                ["graphicsApi"] = SystemInfo.graphicsDeviceType.ToString(),
                ["colorSpace"] = QualitySettings.activeColorSpace.ToString(),
                ["anisotropicFilteringDuringCapture"] = QualitySettings.anisotropicFiltering.ToString(),
                ["cameraPosition"] = new JArray(fixture.Position.x, fixture.Position.y, fixture.Position.z),
                ["cameraEuler"] = new JArray(fixture.Rotation.eulerAngles.x, fixture.Rotation.eulerAngles.y, fixture.Rotation.eulerAngles.z),
                ["fieldOfView"] = fixture.Camera.fieldOfView,
                ["cameraSource"] = "PersonalSpaceMap/HomeCameraReference pose; 58 degree diagnostic lens (not avatar-dependent runtime framing).",
                ["mesh"] = AssetDatabase.GetAssetPath(fixture.Floor.GetComponent<MeshFilter>().sharedMesh),
                ["materials"] = new JArray(fixture.ImportedMaterials.Select(AssetDatabase.GetAssetPath)),
                ["textures"] = fixture.TextureMetadata(),
                ["offsetUnits"] = "x = world camera translation in metres; y = local yaw in degrees",
                ["offsets"] = new JArray(Offsets.Select(o => new JArray(o.x, o.y))),
                ["cases"] = new JArray()
            };
            // Intersect flat-color coverage across the complete path and erode
            // it, so moving silhouettes do not dominate the interior metrics.
            fixture.UseFlatMaterial();
            bool[] mask = null;
            foreach (Vector2 offset in Offsets)
            {
                fixture.SetPose(offset);
                Color32[] pixels = fixture.Capture();
                if (mask == null) mask = Enumerable.Repeat(true, pixels.Length).ToArray();
                for (int i = 0; i < mask.Length; i++) mask[i] &= pixels[i].g > 30 && pixels[i].b < 240;
            }
            mask = Erode(mask, size.x, size.y);
            int covered = mask.Count(value => value);
            Assert.That(covered, Is.GreaterThan(0), "The real floor must be visible from the authored Home reference.");
            report["interiorFloorPixels"] = covered;

            foreach (string variant in new[] { "imported", "bilinear_aniso1", "trilinear_aniso8", "flat_geometry_control" })
            {
                fixture.UseVariant(variant);
                var evidence = new JObject { ["name"] = variant };
                var fixedDeltas = new JArray();
                var movingDeltas = new JArray();
                Color32[] previous = null;
                fixture.SetPose(Vector2.zero);
                // Distinct Editor updates are essential: a static user view
                // can flicker without any camera input. Record wall time too.
                for (int frame = 0; frame < 8; frame++)
                {
                    yield return null;
                    Color32[] pixels = fixture.Capture(frame == 0 || frame == 7
                        ? Path.Combine(Output, $"{prefix}-{variant}-fixed-{frame}.png") : null);
                    if (previous != null) fixedDeltas.Add(Delta(previous, pixels, mask, frame));
                    previous = pixels;
                }
                evidence["fixedCameraConsecutiveFrames"] = fixedDeltas;
                previous = null;
                for (int frame = 0; frame < Offsets.Length; frame++)
                {
                    fixture.SetPose(Offsets[frame]);
                    yield return null;
                    Color32[] pixels = fixture.Capture(frame == 0 || frame == 2 || frame == 6
                        ? Path.Combine(Output, $"{prefix}-{variant}-motion-{frame}.png") : null);
                    if (previous != null) movingDeltas.Add(Delta(previous, pixels, mask, frame));
                    previous = pixels;
                }
                evidence["movingCameraConsecutiveFrames"] = movingDeltas;
                ((JArray)report["cases"]).Add(evidence);
                File.WriteAllText(Path.Combine(Output, $"floor-stability-{prefix}.json"), report.ToString());
                TestContext.Out.WriteLine($"{prefix} {variant}: fixed mean RGB8 delta={AverageDelta(fixedDeltas):F5}, moving={AverageDelta(movingDeltas):F5}; interior pixels={covered}.");
            }
        }
        TestContext.Out.WriteLine($"Floor diagnostic images and JSON: {Output}. Pixel differences are measurements, not a flicker diagnosis.");
    }

    private static double AverageDelta(JArray values) => values.Average(value => (double)value["meanAbsoluteRgb8"]);

    private static JObject Delta(Color32[] before, Color32[] after, bool[] mask, int frame)
    {
        double absolute = 0, squared = 0;
        int count = 0, changed = 0, over8 = 0, max = 0;
        for (int i = 0; i < mask.Length; i++)
        {
            if (!mask[i]) continue;
            int r = Math.Abs(before[i].r - after[i].r), g = Math.Abs(before[i].g - after[i].g), b = Math.Abs(before[i].b - after[i].b);
            int peak = Math.Max(r, Math.Max(g, b));
            absolute += r + g + b;
            squared += r * r + g * g + b * b;
            count++;
            if (peak > 0) changed++;
            if (peak >= 8) over8++;
            max = Math.Max(max, peak);
        }
        return new JObject
        {
            ["frame"] = frame, ["realtimeSeconds"] = Time.realtimeSinceStartup,
            ["meanAbsoluteRgb8"] = absolute / (count * 3),
            ["rootMeanSquareRgb8"] = Math.Sqrt(squared / (count * 3)),
            ["maximumChannelDelta8"] = max,
            ["changedPixelFraction"] = (double)changed / count,
            ["pixelFractionWithChannelDeltaAtLeast8"] = (double)over8 / count
        };
    }

    private static bool[] Erode(bool[] source, int width, int height)
    {
        var result = new bool[source.Length];
        for (int y = 2; y < height - 2; y++)
        for (int x = 2; x < width - 2; x++)
        {
            bool inside = true;
            for (int dy = -2; dy <= 2 && inside; dy++)
            for (int dx = -2; dx <= 2; dx++)
                if (!source[(y + dy) * width + x + dx]) { inside = false; break; }
            result[y * width + x] = inside;
        }
        return result;
    }

    private sealed class Sampler
    {
        public readonly Texture Texture;
        public readonly FilterMode Filter;
        public readonly int Aniso;
        public Sampler(Texture texture) { Texture = texture; Filter = texture.filterMode; Aniso = texture.anisoLevel; }
        public void Restore() { Texture.filterMode = Filter; Texture.anisoLevel = Aniso; }
    }

    private sealed class Fixture : IDisposable
    {
        public readonly Camera Camera;
        public readonly Renderer Floor;
        public readonly RenderTexture Target;
        public readonly Vector3 Position;
        public readonly Quaternion Rotation;
        public readonly Material[] ImportedMaterials;
        private readonly Scene scene;
        private readonly List<Object> temporary = new();
        private readonly List<Sampler> samplers = new();
        private readonly Material[] clonedMaterials;
        private readonly Material flat;
        private readonly Texture2D image;
        private readonly bool oldFog;
        private readonly float oldNight;
        private readonly AnisotropicFiltering oldAnisotropic;

        public Fixture(int width, int height)
        {
            oldFog = RenderSettings.fog;
            oldNight = Shader.GetGlobalFloat("_MaasoWorldNightBlend");
            oldAnisotropic = QualitySettings.anisotropicFiltering;
            scene = EditorSceneManager.NewPreviewScene();
            try
            {
                var holder = new GameObject("FloorDiagnosticPreview");
                SceneManager.MoveGameObjectToScene(holder, scene);
                GameObject prefab = Resources.Load<GameObject>("PersonalSpaceMap");
                Assert.That(prefab, Is.Not.Null);
                GameObject clone = Object.Instantiate(prefab, holder.transform);
                foreach (Behaviour behaviour in clone.GetComponentsInChildren<Behaviour>(true)) behaviour.enabled = false;
                Floor = clone.GetComponentsInChildren<Renderer>(true).Single(value => value.name == "V4_Floor_Baked");
                foreach (Renderer renderer in clone.GetComponentsInChildren<Renderer>(true)) renderer.enabled = renderer == Floor;
                for (Transform parent = Floor.transform; parent != null; parent = parent.parent) parent.gameObject.SetActive(true);
                Transform reference = clone.GetComponentsInChildren<Transform>(true).Single(value => value.name == "HomeCameraReference");
                Position = reference.position;
                Rotation = reference.rotation;
                ImportedMaterials = Floor.sharedMaterials;
                clonedMaterials = ImportedMaterials.Select(material => Track(new Material(material))).ToArray();
                foreach (Texture texture in ImportedMaterials.SelectMany(material => material.GetTexturePropertyNames().Select(material.GetTexture)).Where(texture => texture != null).Distinct())
                    samplers.Add(new Sampler(texture));
                flat = Track(new Material(Shader.Find("Unlit/Color")));
                flat.color = new Color(.5f, .6f, .4f, 1);
                Assert.That(clonedMaterials.All(material => material.shader.isSupported && !ShaderUtil.ShaderHasError(material.shader)), Is.True);
                Target = Track(new RenderTexture(width, height, 24, RenderTextureFormat.ARGB32, RenderTextureReadWrite.sRGB)
                { antiAliasing = 1, hideFlags = HideFlags.HideAndDontSave });
                Target.Create();
                image = Track(new Texture2D(width, height, TextureFormat.RGB24, false, false));
                var cameraObject = new GameObject("IsolatedFloorCamera");
                SceneManager.MoveGameObjectToScene(cameraObject, scene);
                Camera = cameraObject.AddComponent<Camera>();
                Camera.enabled = false;
                Camera.scene = scene;
                Camera.clearFlags = CameraClearFlags.SolidColor;
                Camera.backgroundColor = Color.magenta;
                Camera.allowHDR = false;
                Camera.allowMSAA = false;
                Camera.fieldOfView = 58;
                Camera.aspect = (float)width / height;
                Camera.nearClipPlane = .03f;
                Camera.farClipPlane = 100;
                Camera.targetTexture = Target;
                Camera.useOcclusionCulling = false;
                RenderSettings.fog = false;
                Shader.SetGlobalFloat("_MaasoWorldNightBlend", 0);
                QualitySettings.anisotropicFiltering = AnisotropicFiltering.Enable;
                SetPose(Vector2.zero);
            }
            catch { Dispose(); throw; }
        }

        private T Track<T>(T value) where T : Object { temporary.Add(value); return value; }
        public void SetPose(Vector2 offset) => Camera.transform.SetPositionAndRotation(
            Position + Vector3.right * offset.x, Rotation * Quaternion.Euler(0, offset.y, 0));
        public void UseFlatMaterial() => Floor.sharedMaterials = Enumerable.Repeat(flat, ImportedMaterials.Length).ToArray();
        public void UseVariant(string variant)
        {
            foreach (Sampler sampler in samplers) sampler.Restore();
            if (variant == "flat_geometry_control") { UseFlatMaterial(); return; }
            Floor.sharedMaterials = clonedMaterials;
            if (variant == "imported") return;
            foreach (Sampler sampler in samplers)
            {
                sampler.Texture.filterMode = variant == "bilinear_aniso1" ? FilterMode.Bilinear : FilterMode.Trilinear;
                sampler.Texture.anisoLevel = variant == "bilinear_aniso1" ? 1 : 8;
            }
        }

        public JArray TextureMetadata() => new(samplers.Select(sampler => new JObject
        {
            ["path"] = AssetDatabase.GetAssetPath(sampler.Texture),
            ["width"] = sampler.Texture.width, ["height"] = sampler.Texture.height,
            ["mipCount"] = sampler.Texture is Texture2D value ? value.mipmapCount : 0,
            ["originalFilter"] = sampler.Filter.ToString(), ["originalAniso"] = sampler.Aniso
        }));

        public Color32[] Capture(string png = null)
        {
            RenderTexture previous = RenderTexture.active;
            try
            {
                Camera.Render();
                RenderTexture.active = Target;
                image.ReadPixels(new Rect(0, 0, Target.width, Target.height), 0, 0);
                image.Apply(false, false);
                if (png != null) File.WriteAllBytes(png, image.EncodeToPNG());
                return image.GetPixels32();
            }
            finally { RenderTexture.active = previous; }
        }

        public void Dispose()
        {
            // Never save/reimport: restore all shared texture samplers even if
            // capture, image encoding or assertions fail.
            foreach (Sampler sampler in samplers) sampler.Restore();
            QualitySettings.anisotropicFiltering = oldAnisotropic;
            Shader.SetGlobalFloat("_MaasoWorldNightBlend", oldNight);
            if (Camera != null) Camera.targetTexture = null;
            if (scene.IsValid()) EditorSceneManager.ClosePreviewScene(scene);
            RenderSettings.fog = oldFog;
            if (Target != null) Target.Release();
            foreach (Object value in temporary) if (value != null) Object.DestroyImmediate(value);
        }
    }
}

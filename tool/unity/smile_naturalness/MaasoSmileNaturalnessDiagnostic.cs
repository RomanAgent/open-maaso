using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using Maaso.Avatar;
using Newtonsoft.Json.Linq;
using UniVRM10;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using Object = UnityEngine.Object;

// Temporary controlled diagnostic. Removed after capture; no source asset writes.
public static class MaasoSmileNaturalnessDiagnostic
{
    const string Output = "/private/tmp/maaso-smile-naturalness-snapshot-20261018";
    const BindingFlags Flags = BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public;
    static object Call(object target, string name, params object[] args) => target.GetType().GetMethods(Flags)
        .Single(m => m.Name == name && m.GetParameters().Length == args.Length).Invoke(target, args);
    static object Field(object target, string name) => target.GetType().GetField(name, Flags).GetValue(target);
    static void Set(object target, string name, object value) => target.GetType().GetField(name, Flags).SetValue(target, value);
    static void Send(Component receiver, string method, JObject value) => Call(receiver, "OnFlutterCommand",
        new JObject { ["method"] = method, ["json"] = value.ToString() }.ToString());

    public static void Run()
    {
        Directory.CreateDirectory(Output);
        try
        {
            foreach (string model in new[] { "Joy" }) CaptureModel(model);
            File.WriteAllText(Path.Combine(Output, "complete.txt"), DateTime.UtcNow.ToString("O"));
        }
        catch (Exception e)
        {
            File.WriteAllText(Path.Combine(Output, "failure.txt"), e.ToString());
            throw;
        }
        finally { EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single); }
    }

    static void CaptureModel(string model)
    {
        EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
        Component receiver = Object.FindAnyObjectByType<UnityAvatarCommandReceiver>();
        Call(receiver, "Awake");
        Transform root = receiver.GetType().GetProperty("ActiveAvatarRoot").GetValue(receiver) as Transform;
        Animator animator = root.GetComponentInChildren<Animator>(true);
        animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
        animator.Rebind(); animator.Update(0f);
        Send(receiver, "setLocalAvatarVisible", new JObject { ["visible"] = true });
        float origin = Time.realtimeSinceStartup;
        for (int frame = 1; frame <= 90; frame++)
        {
            Call(receiver, "Update"); animator.Update(1f / 60f);
            root.GetComponentInChildren<Vrm10Instance>(true)?.Runtime.Process();
            Call(receiver, "AdvancePresentationFrame", origin + frame / 60f,
                DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + (long)(frame * 1000f / 60f));
        }
        Vrm10Instance vrm = root.GetComponentInChildren<Vrm10Instance>(true);
        SkinnedMeshRenderer[] skins = root.GetComponentsInChildren<SkinnedMeshRenderer>(true);
        var report = new JObject { ["model"] = model, ["root"] = root.name,
            ["scope"] = "Controlled Editor production receiver and VRM/native expression processing; CPU BakeMesh render reference. Sequence demonstrates neutral, a brief warm smile, neutral, broader smile with real viseme cues and release. Not a full iOS GPU or human perceptual validation.",
            ["states"] = new JArray() };
        if (vrm != null)
        {
            var clips = new JArray();
            foreach (var item in vrm.Vrm.Expression.Clips)
            {
                var bindings = new JArray();
                foreach (var b in item.Clip.MorphTargetBindings ?? Array.Empty<MorphTargetBinding>())
                {
                    Transform t = string.IsNullOrEmpty(b.RelativePath) ? vrm.transform : vrm.transform.Find(b.RelativePath);
                    var skin = t == null ? null : t.GetComponent<SkinnedMeshRenderer>();
                    bindings.Add(new JObject { ["path"] = b.RelativePath, ["index"] = b.Index,
                        ["name"] = skin?.sharedMesh?.GetBlendShapeName(b.Index), ["weight"] = b.Weight });
                }
                clips.Add(new JObject { ["key"] = item.Preset.ToString(), ["bindings"] = bindings,
                    ["definition"] = EditorJsonUtility.ToJson(item.Clip) });
            }
            report["vrmClips"] = clips;
        }
        var camera = new GameObject("Controlled Studio Camera").AddComponent<Camera>();
        camera.clearFlags = CameraClearFlags.SolidColor; camera.backgroundColor = new Color(.57f,.57f,.57f,1);
        camera.fieldOfView = 32f; camera.aspect = 1f; camera.nearClipPlane = .01f; camera.farClipPlane = 10f;
        Transform head = animator.GetBoneTransform(HumanBodyBones.Head);
        Vector3 focus = head.position + Vector3.up * .045f;
        Vector3 forward = root.forward; forward.y = 0; forward.Normalize();
        camera.transform.position = focus + forward * .68f;
        camera.transform.LookAt(focus, Vector3.up);
        foreach (Light light in Object.FindObjectsByType<Light>(FindObjectsSortMode.None)) light.enabled = false;
        RenderSettings.ambientMode = UnityEngine.Rendering.AmbientMode.Flat;
        RenderSettings.ambientLight = new Color(.5f,.5f,.5f);
        AddLight("Studio Key", focus + forward * 2f + Vector3.up * 1f + camera.transform.right * 1f, focus, 1f);
        AddLight("Studio Fill", focus + forward * 2f - camera.transform.right * 1f, focus, .4f);
        foreach (Renderer renderer in Object.FindObjectsByType<Renderer>(FindObjectsSortMode.None))
            if (!renderer.transform.IsChildOf(root)) renderer.enabled = false;
        report["studio"] = new JObject { ["distance"] = .68f, ["fov"] = 32f,
            ["focus"] = new JArray(focus.x, focus.y, focus.z),
            ["cameraPosition"] = new JArray(camera.transform.position.x, camera.transform.position.y, camera.transform.position.z) };
        string[] labels = { "source-neutral", "runtime-neutral", "polite-smile", "warm-smile", "broad-smile",
            "smiling-aa", "smiling-ih", "smiling-ou", "smiling-ee", "smiling-oh", "smiling-pp", "smiling-ff",
            "smiling-silent", "smile-surprised", "release-half", "return-neutral", "thinking-neutral", "tired-neutral" };
        for (int index = 0; index < labels.Length; index++)
        {
            foreach (var skin in skins) if (skin.sharedMesh != null)
                for (int i = 0; i < skin.sharedMesh.blendShapeCount; i++) skin.SetBlendShapeWeight(i, 0);
            Call(receiver, "ResetExpressionTransition");
            Set(receiver, "autoBlinkWeight", 0f);
            Send(receiver, "stopLipSync", new JObject());
            Send(receiver, "setMouthOpen", new JObject { ["value"] = 0f });
            float smile = index <= 1 || index >= 15 ? 0f : index == 2 ? .2f : index == 3 ? .45f : 1f;
            var request = new JObject { ["happy"] = smile, ["mouthSmile"] = smile,
                ["eyeOpen"] = 1f, ["surprised"] = index == 13 ? .6f : 0f,
                ["thinking"] = index == 16 ? .8f : 0f, ["tired"] = index == 17 ? .8f : 0f };
            Send(receiver, "setExpression", request);
            Call(receiver, "UpdateExpressionTransition", Time.realtimeSinceStartup + 1f);
            string viseme = index >= 5 && index <= 12
                ? new[] { "aa", "ih", "ou", "ee", "oh", "pp", "ff", "sil" }[index-5] : null;
            if (viseme != null)
                Send(receiver, "startVisemeTimeline", new JObject { ["format"] = "vrm_viseme_v2",
                    ["envelope"] = new JArray(.2f, 0f), ["cues"] = new JArray(new JObject {
                        ["frame"] = 0, ["viseme"] = viseme }), ["frameRate"] = 30 });
            if (index == 14)
            {
                Send(receiver, "setExpression", new JObject { ["eyeOpen"] = 1f });
                float started = (float)Field(receiver, "expressionTransitionStartedAt");
                Call(receiver, "UpdateExpressionTransition", started + .325f);
            }
            object jawRest = Field(receiver, "humanoidFaceRest");
            if (vrm != null) vrm.Runtime.Process();
            else if (jawRest != null) Call(jawRest, "Apply", (float)Field(receiver, "mouthVisemeAa"));
            Call(Field(receiver, "facialCalibration"), "PresentSpeech");
            if (index == 0)
            {
                foreach (var skin in skins) if (skin.sharedMesh != null)
                    for (int i = 0; i < skin.sharedMesh.blendShapeCount; i++) skin.SetBlendShapeWeight(i, 0f);
                if (jawRest != null) Call(jawRest, "Apply", 0f);
            }
            var state = new JObject { ["label"] = labels[index], ["request"] = request, ["viseme"] = viseme,
                ["morphs"] = Morphs(skins) };
            if (vrm != null)
            {
                var weights = new JArray();
                foreach (ExpressionKey key in vrm.Runtime.Expression.ExpressionKeys)
                    weights.Add(new JObject { ["key"] = key.ToString(),
                        ["requested"] = vrm.Runtime.Expression.GetWeight(key),
                        ["actual"] = vrm.Runtime.Expression.ActualWeights[key] });
                state["vrmWeights"] = weights;
                state["blinkOverrideRate"] = vrm.Runtime.Expression.BlinkOverrideRate;
                state["mouthOverrideRate"] = vrm.Runtime.Expression.MouthOverrideRate;
            }
            string file = model.ToLowerInvariant() + "-" + labels[index] + ".png";
            Render(camera, root, skins, Path.Combine(Output, file));
            state["image"] = file;
            ((JArray)report["states"]).Add(state);
        }
        var sequence = new JArray();
        Send(receiver, "stopLipSync", new JObject());
        Call(receiver, "ResetExpressionTransition");
        Call(receiver, "ApplyExpression");
        float sequenceStart = Time.realtimeSinceStartup;
        for (int frame = 0; frame < 60; frame++)
        {
            float now = sequenceStart + frame / 10f;
            float? nextSmile = frame == 2 ? .45f : frame == 14 || frame == 47 ? 0f : frame == 25 ? 1f : (float?)null;
            if (nextSmile.HasValue)
            {
                Send(receiver, "setExpression", new JObject { ["happy"] = nextSmile.Value,
                    ["mouthSmile"] = nextSmile.Value, ["eyeOpen"] = 1f });
                Set(receiver, "expressionTransitionStartedAt", now);
            }
            Call(receiver, "UpdateExpressionTransition", now);
            if (frame == 34)
                Send(receiver, "startVisemeTimeline", new JObject { ["format"] = "vrm_viseme_v2",
                    ["envelope"] = new JArray(.2f, .2f, 0f), ["cues"] = new JArray(
                        new JObject { ["frame"] = 0, ["viseme"] = "aa" },
                        new JObject { ["frame"] = 1, ["viseme"] = "ou" },
                        new JObject { ["frame"] = 2, ["viseme"] = "sil" }), ["frameRate"] = 1 });
            if (frame >= 34 && frame <= 44) Call(receiver, "ApplyLipSyncFrame", (frame - 34) / 5f);
            if (frame == 45) Send(receiver, "stopLipSync", new JObject());
            if (vrm != null) vrm.Runtime.Process();
            else
            {
                object jawRest = Field(receiver, "humanoidFaceRest");
                if (jawRest != null) Call(jawRest, "Apply", Mathf.Max((float)Field(receiver, "mouthVisemeAa"),
                    (float)Field(receiver, "mouthVisemeOh"), (float)Field(receiver, "mouthVisemeOu")));
            }
            Call(Field(receiver, "facialCalibration"), "PresentSpeech");
            string file = model.ToLowerInvariant() + "-sequence-" + frame.ToString("D3") + ".png";
            Render(camera, root, skins, Path.Combine(Output, file));
            sequence.Add(new JObject { ["frame"] = frame, ["seconds"] = frame / 10f,
                ["image"] = file, ["morphs"] = Morphs(skins) });
        }
        report["sequence"] = sequence;
        File.WriteAllText(Path.Combine(Output, model.ToLowerInvariant() + "-report.json"), report.ToString());
        Call(receiver, "OnDisable");
    }

    public static void Geometry()
    {
        EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
        var body = Object.FindAnyObjectByType<Vrm10Instance>().GetComponentsInChildren<SkinnedMeshRenderer>(true)
            .Single(s => s.sharedMesh != null && s.sharedMesh.GetBlendShapeIndex("lip_smile.L") >= 0);
        Mesh mesh = body.sharedMesh;
        var result = new JArray();
        foreach (string side in new[] { "L", "R" })
        {
            var a = new Vector3[mesh.vertexCount]; var b = new Vector3[mesh.vertexCount];
            mesh.GetBlendShapeFrameVertices(mesh.GetBlendShapeIndex("lip_smile." + side), 0, a, null, null);
            mesh.GetBlendShapeFrameVertices(mesh.GetBlendShapeIndex("Smile_" + side), 0, b, null, null);
            double dot = 0, aa = 0, bb = 0, residual = 0; float maxA = 0, maxB = 0, maxCombined = 0, maxDifference = 0;
            int countA = 0, countB = 0;
            for (int i=0; i<a.Length; i++)
            {
                dot += Vector3.Dot(a[i],b[i]); aa += a[i].sqrMagnitude; bb += b[i].sqrMagnitude;
                residual += (a[i]-b[i]).sqrMagnitude;
                maxA = Mathf.Max(maxA,a[i].magnitude); maxB = Mathf.Max(maxB,b[i].magnitude);
                maxDifference = Mathf.Max(maxDifference,(a[i]-b[i]).magnitude);
                maxCombined = Mathf.Max(maxCombined,(a[i]*.7f+b[i]*.25f).magnitude);
                if(a[i].sqrMagnitude>1e-14f)countA++;if(b[i].sqrMagnitude>1e-14f)countB++;
            }
            result.Add(new JObject { ["side"] = side, ["mesh"] = mesh.name, ["vertices"] = mesh.vertexCount,
                ["deltaCosine"] = dot/Math.Sqrt(aa*bb), ["rmsDifferenceMeshUnits"] = Math.Sqrt(residual/a.Length),
                ["maxDifferenceMeshUnits"] = maxDifference, ["maxLipSmileDeltaMeshUnits"] = maxA,
                ["maxRestSmileDeltaMeshUnits"] = maxB, ["maxCombinedAt70Plus25MeshUnits"] = maxCombined,
                ["lipAffectedVertices"] = countA, ["restAffectedVertices"] = countB });
        }
        File.WriteAllText(Path.Combine(Output,"joy-smile-delta-geometry.json"),result.ToString());
        EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
    }

    static JArray Morphs(SkinnedMeshRenderer[] skins)
    {
        var result = new JArray();
        foreach (var skin in skins)
        {
            if (skin.sharedMesh == null || skin.sharedMesh.blendShapeCount == 0) continue;
            var weights = new JObject();
            for (int i = 0; i < skin.sharedMesh.blendShapeCount; i++)
                weights[skin.sharedMesh.GetBlendShapeName(i)] = skin.GetBlendShapeWeight(i);
            result.Add(new JObject { ["renderer"] = skin.name, ["weights"] = weights });
        }
        return result;
    }
    static void AddLight(string name, Vector3 position, Vector3 focus, float intensity)
    {
        var light = new GameObject(name).AddComponent<Light>(); light.type = LightType.Directional;
        light.intensity = intensity; light.color = Color.white;
        light.transform.position = position; light.transform.LookAt(focus);
        light.shadows = LightShadows.None;
    }
    static void Render(Camera camera, Transform root, SkinnedMeshRenderer[] skins, string path)
    {
        if (File.Exists(path)) throw new IOException("Refusing to overwrite evidence: " + path);
        var meshes = new List<Mesh>(); var objects = new List<GameObject>(); var enabled = new List<SkinnedMeshRenderer>();
        var target = new RenderTexture(768,768,24,RenderTextureFormat.ARGB32);
        var image = new Texture2D(768,768,TextureFormat.RGBA32,false);
        var previous = RenderTexture.active;
        try
        {
            foreach (var skin in skins)
            {
                if (!skin.enabled || skin.forceRenderingOff || !skin.gameObject.activeInHierarchy) continue;
                var mesh = new Mesh(); skin.BakeMesh(mesh); meshes.Add(mesh);
                var clone = new GameObject("Controlled CPU skin snapshot"); objects.Add(clone);
                clone.transform.SetParent(skin.transform,false); clone.layer = skin.gameObject.layer;
                clone.AddComponent<MeshFilter>().sharedMesh = mesh;
                clone.AddComponent<MeshRenderer>().sharedMaterials = skin.sharedMaterials;
                skin.enabled = false; enabled.Add(skin);
            }
            target.Create(); camera.targetTexture = target; camera.Render(); RenderTexture.active = target;
            image.ReadPixels(new Rect(0,0,768,768),0,0); image.Apply();
            File.WriteAllBytes(path,image.EncodeToPNG());
        }
        finally
        {
            foreach (var skin in enabled) if (skin != null) skin.enabled = true;
            foreach (var clone in objects) Object.DestroyImmediate(clone);
            foreach (var mesh in meshes) Object.DestroyImmediate(mesh);
            camera.targetTexture = null; RenderTexture.active = previous;
            Object.DestroyImmediate(image); target.Release(); Object.DestroyImmediate(target);
        }
    }
}

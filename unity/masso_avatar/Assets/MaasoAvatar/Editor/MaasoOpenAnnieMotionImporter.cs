#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using Newtonsoft.Json.Linq;
using UniGLTF;
using UniVRM10;
using UnityEditor;
using UnityEditor.Animations;
using UnityEngine;
using Object = UnityEngine.Object;

namespace Maaso.Avatar.Editor
{
    /// <summary>Preserves pinned normalized FK for direct VRM playback and
    /// keeps native Humanoid clips for other rigs. Does not alter source art.</summary>
    public static class MaasoOpenAnnieMotionImporter
    {
        public const string SourceDirectory = "Assets/MaasoAvatar/Editor/OpenAnnieSource";
        public const string ClipDirectory = "Assets/MaasoAvatar/Animations/Humanoid/OpenAnnie";
        public const string NormalizedDirectory = "Assets/MaasoAvatar/Animations/Normalized/OpenAnnie";
        public const string ControllerPath = "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller";
        public const string LibraryPath = "Assets/MaasoAvatar/Resources/OpenAnnieMotionLibrary.asset";
        public const string MaskPath = ClipDirectory + "/OpenAnnieUpperBody.mask";
        private const string ReferenceModel = "Assets/MaasoAvatar/Models/Default/Joy.vrm";

        [MenuItem("Maaso/Actions/Import Open Annie CC0 Motions", false, 12)]
        public static void RunFromCommandLine()
        {
            JObject pack = JObject.Parse(File.ReadAllText(SourceDirectory + "/pack.json"));
            Require((string)pack["space"] == "vrm1-normalized", "Unsupported motion space.");
            Require((string)pack["license"] == "CC0-1.0", "Unexpected motion licence.");
            var definitions = (JObject)pack["clips"];
            Require(definitions.Count == 63, "The reviewed pack must contain exactly 63 clips.");
            string packHash = Sha256(File.ReadAllBytes(SourceDirectory + "/pack.json"));
            EnsureFolder(ClipDirectory);
            EnsureFolder(NormalizedDirectory);
            EnsureFolder("Assets/MaasoAvatar/Resources");
            var entries = new List<OpenAnnieMotionLibrary.Entry>();
            using (var reference = new BakeReference())
            {
                foreach (JProperty property in definitions.Properties().OrderBy(p => p.Name, StringComparer.Ordinal))
                {
                    JObject metadata = (JObject)property.Value;
                    string filename = (string)metadata["file"];
                    Require(filename == property.Name + ".json", "Invalid source filename.");
                    byte[] bytes = File.ReadAllBytes(SourceDirectory + "/" + filename);
                    Require(bytes.LongLength == (long)metadata["bytes"] &&
                        Sha256(bytes) == (string)metadata["sha256"], "Motion source integrity failure: " + filename);
                    JObject data = JObject.Parse(System.Text.Encoding.UTF8.GetString(bytes));
                    var entry = MakeEntry(property.Name, metadata, data);
                    AnimationClip clip = Bake(reference, data, (JObject)pack["hands"], entry);
                    entry.Clip = SaveClip(clip, ClipDirectory + "/" + entry.Id + ".anim");
                    entry.NormalizedPose = SaveNormalizedPose(data, (JObject)pack["hands"], entry, packHash);
                    entries.Add(entry);
                }
            }
            OpenAnnieMotionLibrary library = AssetDatabase.LoadAssetAtPath<OpenAnnieMotionLibrary>(LibraryPath);
            if (library == null)
            {
                library = ScriptableObject.CreateInstance<OpenAnnieMotionLibrary>();
                AssetDatabase.CreateAsset(library, LibraryPath);
            }
            library.Entries = entries.ToArray();
            library.SourceCommit = OpenAnnieMotionLibrary.UpstreamCommit;
            library.License = "CC0-1.0";
            EditorUtility.SetDirty(library);
            AttachController(library);
            AssetDatabase.SaveAssets();
            NormalizeControllerSerialization();
            Debug.Log("[OpenAnnie] Baked and registered 63 CC0 Humanoid motions; source commit " + library.SourceCommit);
        }

        /// <summary>Rebuild only source-preserving FK data. Existing Humanoid
        /// clips/controller remain untouched as the non-VRM retarget fallback.</summary>
        public static void ImportNormalizedPoses()
        {
            JObject pack = JObject.Parse(File.ReadAllText(SourceDirectory + "/pack.json"));
            Require((string)pack["space"] == "vrm1-normalized" && (string)pack["license"] == "CC0-1.0",
                "Unreviewed normalized source pack.");
            var definitions = (JObject)pack["clips"];
            Require(definitions.Count == 63, "The reviewed pack must contain exactly 63 clips.");
            var library = AssetDatabase.LoadAssetAtPath<OpenAnnieMotionLibrary>(LibraryPath);
            Require(library != null && library.SourceCommit == OpenAnnieMotionLibrary.UpstreamCommit,
                "Pinned motion library missing.");
            string packHash = Sha256(File.ReadAllBytes(SourceDirectory + "/pack.json"));
            EnsureFolder(NormalizedDirectory);
            foreach (OpenAnnieMotionLibrary.Entry entry in library.Entries)
            {
                Require(entry.Id.StartsWith(OpenAnnieMotionLibrary.IdPrefix, StringComparison.Ordinal), "Unexpected motion id.");
                string name = entry.Id.Substring(OpenAnnieMotionLibrary.IdPrefix.Length);
                var metadata = (JObject)definitions[name];
                Require(metadata != null && (string)metadata["file"] == name + ".json", "Source metadata missing.");
                byte[] bytes = File.ReadAllBytes(SourceDirectory + "/" + name + ".json");
                Require(bytes.LongLength == (long)metadata["bytes"] && Sha256(bytes) == entry.SourceSha256 &&
                    entry.SourceSha256 == (string)metadata["sha256"], "Source integrity failure: " + name);
                JObject data = JObject.Parse(System.Text.Encoding.UTF8.GetString(bytes));
                entry.NormalizedPose = SaveNormalizedPose(data, (JObject)pack["hands"], entry, packHash);
            }
            EditorUtility.SetDirty(library);
            AssetDatabase.SaveAssets();
            Debug.Log("[OpenAnnie] Preserved normalized FK for " + library.Entries.Length + " reviewed source clips.");
        }

        private static OpenAnnieNormalizedPoseClip SaveNormalizedPose(JObject data, JObject hands,
            OpenAnnieMotionLibrary.Entry entry, string packHash)
        {
            int frames = (int)data["frames"];
            Require((string)data["space"] == "vrm1-normalized" && frames >= 2 && (float)data["fps"] == 30f &&
                (bool)data["loop"] == entry.Loop, "Invalid source FK sampling contract.");
            var tracks = new Dictionary<HumanBodyBones, Quaternion[]>();
            foreach (HumanBodyBones bone in Enum.GetValues(typeof(HumanBodyBones)))
                if (OpenAnnieNormalizedPoseClip.IsArmOrFinger(bone) || OpenAnnieNormalizedPoseClip.TorsoWeight(bone) > 0f)
                    tracks.Add(bone, new[] { Quaternion.identity });
            foreach (JProperty hand in hands.Properties())
            {
                Require(TryMapBone(hand.Name, out var bone), "Unknown rest-hand bone.");
                if (tracks.ContainsKey(bone)) tracks[bone] = new[] { SourceNormalizedQuaternion(hand.Value.ToObject<float[]>(), 0) };
            }
            foreach (JProperty source in ((JObject)data["bones"]).Properties())
            {
                Require(TryMapBone(source.Name, out var bone), "Unknown source FK bone.");
                if (!tracks.ContainsKey(bone)) continue;
                float[] values = source.Value.ToObject<float[]>();
                Require(values.Length == frames * 4 && values.All(Finite), "Invalid source FK track.");
                var rotations = new Quaternion[frames];
                for (int frame = 0; frame < frames; frame++) rotations[frame] = SourceNormalizedQuaternion(values, frame * 4);
                // Exact constant tracks only; no quaternion approximation or
                // float tolerance, resampling, muscle projection or fitting.
                bool constant = rotations.All(q => q.x == rotations[0].x && q.y == rotations[0].y &&
                    q.z == rotations[0].z && q.w == rotations[0].w);
                tracks[bone] = constant ? new[] { rotations[0] } : rotations;
            }
            string path = NormalizedDirectory + "/" + entry.Id + ".asset";
            var saved = AssetDatabase.LoadAssetAtPath<OpenAnnieNormalizedPoseClip>(path);
            if (saved == null)
            {
                saved = ScriptableObject.CreateInstance<OpenAnnieNormalizedPoseClip>();
                AssetDatabase.CreateAsset(saved, path);
            }
            saved.Frames = frames;
            saved.FramesPerSecond = 30f;
            saved.Loop = entry.Loop;
            saved.SourceSha256 = entry.SourceSha256;
            saved.SourcePackSha256 = packHash;
            saved.SourceCommit = OpenAnnieMotionLibrary.UpstreamCommit;
            saved.Tracks = tracks.OrderBy(pair => (int)pair.Key).Select(pair =>
                new OpenAnnieNormalizedPoseClip.Track { Bone = pair.Key, Rotations = pair.Value }).ToArray();
            EditorUtility.SetDirty(saved);
            return saved;
        }

        private static Quaternion SourceNormalizedQuaternion(float[] values, int offset)
        {
            Quaternion q = new Quaternion(values[offset], values[offset + 1], values[offset + 2], values[offset + 3]);
            Require(Finite(q.x) && Finite(q.y) && Finite(q.z) && Finite(q.w) &&
                Mathf.Abs(Quaternion.Dot(q, q) - 1f) < .002f, "Invalid source normalized quaternion.");
            // Exact X-handedness reflection. The pinned SDK's general-purpose
            // ReverseX uses ToAngleAxis + AngleAxis, which loses precision near
            // identity; source FK must not take that lossy round trip.
            return new Quaternion(q.x, -q.y, -q.z, q.w).normalized;
        }

        private static OpenAnnieMotionLibrary.Entry MakeEntry(string name, JObject metadata, JObject data)
        {
            Require(name.All(c => char.IsLower(c) || char.IsDigit(c) || c == '_'), "Invalid motion id.");
            int frames = (int)data["frames"];
            float fps = (float)data["fps"];
            bool loop = (bool)data["loop"];
            Require((string)data["space"] == "vrm1-normalized" && frames >= 2 && fps == 30f,
                "Invalid motion sampling contract: " + name);
            Require(frames == (int)metadata["frames"] && loop == (bool)metadata["loop"], "Manifest mismatch: " + name);
            string layer = (string)metadata["layer"] ?? "body";
            return new OpenAnnieMotionLibrary.Entry
            {
                Id = OpenAnnieMotionLibrary.IdPrefix + name,
                UpperBody = layer == "talk" || layer == "gesture",
                Loop = loop,
                Duration = (loop ? frames : frames - 1) / fps,
                Category = (string)metadata["kind"] ?? "gesture",
                Layer = layer,
                Description = (string)metadata["when"] ?? name,
                Energy = (string)metadata["energy"] ?? string.Empty,
                Hands = (string)metadata["hands"] ?? string.Empty,
                Rest = (string)metadata["rest"] ?? string.Empty,
                Contact = (bool?)metadata["contact"] ?? false,
                PreparationEnd = (float?)metadata["prep_end"] ?? -1f,
                Stroke = (float?)metadata["stroke"] ?? -1f,
                RetractionStart = (float?)metadata["retract_start"] ?? -1f,
                Strokes = metadata["strokes"]?.ToObject<float[]>() ?? Array.Empty<float>(),
                SourceSha256 = (string)metadata["sha256"],
            };
        }

        private static AnimationClip Bake(BakeReference reference, JObject data, JObject hands,
            OpenAnnieMotionLibrary.Entry entry)
        {
            int frames = (int)data["frames"];
            var bones = (JObject)data["bones"];
            var tracks = new Dictionary<HumanBodyBones, float[]>();
            foreach (JProperty bone in bones.Properties())
            {
                Require(TryMapBone(bone.Name, out HumanBodyBones mapped), "Unknown VRM bone: " + bone.Name);
                float[] values = bone.Value.ToObject<float[]>();
                Require(values.Length == frames * 4 && values.All(Finite), "Invalid bone track: " + bone.Name);
                tracks.Add(mapped, values);
            }
            var restHands = new Dictionary<HumanBodyBones, Quaternion>();
            foreach (JProperty hand in hands.Properties())
            {
                Require(TryMapBone(hand.Name, out HumanBodyBones mapped), "Unknown rest-hand bone.");
                restHands[mapped] = SourceQuaternion(hand.Value.ToObject<float[]>(), 0);
            }
            float[] hips = data["hips_position"]?.ToObject<float[]>();
            Require(hips == null || (hips.Length == frames * 3 && hips.All(Finite)), "Invalid hips track.");
            var curves = new Dictionary<string, List<Keyframe>>(StringComparer.Ordinal);
            HumanPose pose = new HumanPose();
            int samples = entry.Loop ? frames + 1 : frames;
            Quaternion previousBody = Quaternion.identity;
            for (int sample = 0; sample < samples; sample++)
            {
                int frame = sample % frames;
                reference.Reset();
                foreach (var rest in restHands)
                    if (reference.Rig.Bones.TryGetValue(rest.Key, out var bone)) bone.ControlBone.localRotation = rest.Value;
                foreach (var track in tracks)
                {
                    Require(reference.Rig.Bones.TryGetValue(track.Key, out var bone), "Reference rig lacks " + track.Key);
                    bone.ControlBone.localRotation = SourceQuaternion(track.Value, frame * 4);
                }
                if (hips != null)
                    reference.Hips.localPosition = reference.HipsRest + SourcePosition(
                        new Vector3(hips[frame * 3], hips[frame * 3 + 1], hips[frame * 3 + 2]));
                reference.Handler.GetHumanPose(ref pose);
                float time = sample / 30f;
                for (int muscle = 0; muscle < HumanTrait.MuscleCount; muscle++)
                {
                    string name = HumanTrait.MuscleName[muscle];
                    if (!AllowedMuscle(name, entry.UpperBody)) continue;
                    Require(Finite(pose.muscles[muscle]), "Non-finite Humanoid muscle.");
                    Add(curves, CurveMuscleName(name), time, pose.muscles[muscle]);
                }
                if (!entry.UpperBody)
                {
                    Require(Finite(pose.bodyPosition.x) && Finite(pose.bodyPosition.y) && Finite(pose.bodyPosition.z), "Non-finite Humanoid root.");
                    Add(curves, "RootT.x", time, pose.bodyPosition.x);
                    Add(curves, "RootT.y", time, pose.bodyPosition.y);
                    Add(curves, "RootT.z", time, pose.bodyPosition.z);
                    Quaternion rotation = pose.bodyRotation.normalized;
                    if (sample > 0 && Quaternion.Dot(previousBody, rotation) < 0f)
                        rotation = new Quaternion(-rotation.x, -rotation.y, -rotation.z, -rotation.w);
                    previousBody = rotation;
                    Add(curves, "RootQ.x", time, rotation.x);
                    Add(curves, "RootQ.y", time, rotation.y);
                    Add(curves, "RootQ.z", time, rotation.z);
                    Add(curves, "RootQ.w", time, rotation.w);
                }
            }
            var clip = new AnimationClip { name = entry.Id, frameRate = 30f, legacy = false,
                wrapMode = entry.Loop ? WrapMode.Loop : WrapMode.Once };
            foreach (var curve in curves)
            {
                var animation = new AnimationCurve(ReduceExactPlateaus(curve.Value));
                for (int index = 0; index < animation.length; index++)
                {
                    AnimationUtility.SetKeyLeftTangentMode(animation, index, AnimationUtility.TangentMode.Linear);
                    AnimationUtility.SetKeyRightTangentMode(animation, index, AnimationUtility.TangentMode.Linear);
                }
                AnimationUtility.SetEditorCurve(clip,
                    EditorCurveBinding.FloatCurve(string.Empty, typeof(Animator), curve.Key), animation);
            }
            clip.EnsureQuaternionContinuity();
            var settings = AnimationUtility.GetAnimationClipSettings(clip);
            settings.loopTime = entry.Loop;
            settings.loopBlend = false;
            settings.keepOriginalOrientation = true;
            settings.keepOriginalPositionY = true;
            settings.keepOriginalPositionXZ = true;
            settings.loopBlendOrientation = true;
            settings.loopBlendPositionY = true;
            settings.loopBlendPositionXZ = false;
            AnimationUtility.SetAnimationClipSettings(clip, settings);
            Require(clip.humanMotion && clip.length > 0f, "Baked clip is not Humanoid: " + entry.Id);
            return clip;
        }

        private static AnimationClip SaveClip(AnimationClip clip, string path)
        {
            AnimationClip saved = AssetDatabase.LoadAssetAtPath<AnimationClip>(path);
            if (saved == null) { AssetDatabase.CreateAsset(clip, path); return clip; }
            EditorUtility.CopySerialized(clip, saved);
            Object.DestroyImmediate(clip);
            EditorUtility.SetDirty(saved);
            return saved;
        }

        // Unity emits trailing blanks for empty serialized fields. Normalize
        // only this generated controller, preserving all identifiers, scalar
        // values, references and existing line endings. Also usable after an
        // independent FBX reimport saves the same shared controller.
        public static void NormalizeControllerSerialization()
        {
            string original = File.ReadAllText(ControllerPath);
            string normalized = System.Text.RegularExpressions.Regex.Replace(original,
                @"[ \t]+(?=\r?$)", string.Empty, System.Text.RegularExpressions.RegexOptions.Multiline);
            if (normalized == original) return;
            File.WriteAllText(ControllerPath, normalized, new System.Text.UTF8Encoding(false));
            AssetDatabase.ImportAsset(ControllerPath, ImportAssetOptions.ForceSynchronousImport);
        }

        private static void AttachController(OpenAnnieMotionLibrary library)
        {
            AnimatorController controller = AssetDatabase.LoadAssetAtPath<AnimatorController>(ControllerPath);
            Require(controller != null && controller.layers.Length > 0, "Shared controller unavailable.");
            AvatarMask mask = AssetDatabase.LoadAssetAtPath<AvatarMask>(MaskPath);
            if (mask == null) { mask = new AvatarMask(); AssetDatabase.CreateAsset(mask, MaskPath); }
            for (int index = 0; index < (int)AvatarMaskBodyPart.LastBodyPart; index++)
            {
                var part = (AvatarMaskBodyPart)index;
                mask.SetHumanoidBodyPartActive(part, part is AvatarMaskBodyPart.Body or AvatarMaskBodyPart.Head or
                    AvatarMaskBodyPart.LeftArm or AvatarMaskBodyPart.RightArm or
                    AvatarMaskBodyPart.LeftFingers or AvatarMaskBodyPart.RightFingers);
            }
            EditorUtility.SetDirty(mask);
            int upper = Array.FindIndex(controller.layers, layer => layer.name == OpenAnnieMotionLibrary.UpperBodyLayerName);
            if (upper < 0) { controller.AddLayer(OpenAnnieMotionLibrary.UpperBodyLayerName); upper = controller.layers.Length - 1; }
            AnimatorControllerLayer[] layers = controller.layers;
            layers[upper].avatarMask = mask;
            layers[upper].defaultWeight = 0f;
            layers[upper].blendingMode = AnimatorLayerBlendingMode.Override;
            layers[upper].iKPass = false;
            controller.layers = layers;
            AnimatorStateMachine upperMachine = layers[upper].stateMachine;
            AnimatorState empty = upperMachine.states.Select(s => s.state)
                .SingleOrDefault(s => s.name == OpenAnnieMotionLibrary.EmptyUpperBodyState) ??
                upperMachine.AddState(OpenAnnieMotionLibrary.EmptyUpperBodyState);
            empty.motion = null;
            empty.writeDefaultValues = false;
            upperMachine.defaultState = empty;
            foreach (OpenAnnieMotionLibrary.Entry entry in library.Entries)
            {
                AnimatorStateMachine machine = entry.UpperBody ? upperMachine : layers[0].stateMachine;
                AnimatorState state = machine.states.Select(s => s.state).SingleOrDefault(s => s.name == entry.Id)
                    ?? machine.AddState(entry.Id);
                state.motion = entry.Clip;
                state.speed = 1f;
                state.speedParameterActive = false;
                state.writeDefaultValues = !entry.UpperBody;
                state.iKOnFeet = false;
                EditorUtility.SetDirty(state);
            }
            EditorUtility.SetDirty(empty);
            EditorUtility.SetDirty(upperMachine);
            EditorUtility.SetDirty(controller);
        }

        public static bool TryMapBone(string vrmName, out HumanBodyBones bone)
        {
            if (vrmName.EndsWith("ThumbMetacarpal", StringComparison.Ordinal))
                vrmName = vrmName.Replace("ThumbMetacarpal", "ThumbProximal");
            else if (vrmName.EndsWith("ThumbProximal", StringComparison.Ordinal))
                vrmName = vrmName.Replace("ThumbProximal", "ThumbIntermediate");
            return Enum.TryParse(vrmName, true, out bone) && bone != HumanBodyBones.LastBone &&
                bone is not HumanBodyBones.Jaw and not HumanBodyBones.LeftEye and not HumanBodyBones.RightEye;
        }

        public static Quaternion SourceQuaternion(float[] values, int offset)
        {
            Quaternion q = new Quaternion(values[offset], values[offset + 1], values[offset + 2], values[offset + 3]);
            Require(Finite(q.x) && Finite(q.y) && Finite(q.z) && Finite(q.w) &&
                Mathf.Abs(Quaternion.Dot(q, q) - 1f) < .002f, "Invalid source quaternion.");
            return Axes.X.Create().InvertQuaternion(q.normalized);
        }

        public static Vector3 SourcePosition(Vector3 value) => new Vector3(-value.x, value.y, value.z);

        // All baked tracks use linear tangents. A key strictly inside a flat
        // plateau cannot affect their value at any time. Keep both ends of
        // every plateau, every non-flat key, every curve and the clip endpoints.
        // Deliberately use exact equality: no tolerance, fitting or resampling.
        public static Keyframe[] ReduceExactPlateaus(IReadOnlyList<Keyframe> keys)
        {
            if (keys.Count <= 2) return keys.ToArray();
            var reduced = new List<Keyframe>(keys.Count) { keys[0] };
            for (int index = 1; index < keys.Count - 1; index++)
            {
                float value = keys[index].value;
                if (keys[index - 1].value == value && value == keys[index + 1].value) continue;
                reduced.Add(keys[index]);
            }
            reduced.Add(keys[keys.Count - 1]);
            return reduced.ToArray();
        }

        private static bool AllowedMuscle(string name, bool upperBody)
        {
            if (name.Contains("Jaw") || name.Contains("Eye")) return false;
            if (!upperBody) return true;
            return !name.Contains("Leg") && !name.Contains("Foot") && !name.Contains("Toes");
        }

        private static string CurveMuscleName(string name)
        {
            foreach (string side in new[] { "Left", "Right" })
                foreach (string finger in new[] { "Thumb", "Index", "Middle", "Ring", "Little" })
                {
                    string prefix = side + " " + finger + " ";
                    if (name.StartsWith(prefix, StringComparison.Ordinal))
                        return side + "Hand." + finger + "." + name.Substring(prefix.Length);
                }
            return name;
        }

        private static void Add(Dictionary<string, List<Keyframe>> curves, string name, float time, float value)
        {
            if (!curves.TryGetValue(name, out var keys)) curves[name] = keys = new List<Keyframe>();
            keys.Add(new Keyframe(time, value));
        }
        private static bool Finite(float value) => !float.IsNaN(value) && !float.IsInfinity(value);
        private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
        private static string Sha256(byte[] bytes) { using var sha = SHA256.Create(); return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant(); }
        private static void EnsureFolder(string path)
        {
            if (AssetDatabase.IsValidFolder(path)) return;
            string parent = Path.GetDirectoryName(path).Replace('\\', '/');
            EnsureFolder(parent);
            AssetDatabase.CreateFolder(parent, Path.GetFileName(path));
        }

        private sealed class BakeReference : IDisposable
        {
            public readonly GameObject Root;
            public readonly Vrm10RuntimeControlRig Rig;
            public readonly HumanPoseHandler Handler;
            public readonly Transform Hips;
            public readonly Vector3 HipsRest;
            private readonly UnityEngine.Avatar avatar;
            public BakeReference()
            {
                GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(ReferenceModel);
                Require(prefab != null, "Reference VRM missing.");
                Root = Object.Instantiate(prefab);
                Root.name = "OpenAnnieBakeReference";
                Root.hideFlags = HideFlags.HideAndDontSave;
                Root.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
                Root.transform.localScale = Vector3.one;
                Vrm10Instance vrm = Root.GetComponent<Vrm10Instance>();
                vrm.enabled = false;
                Animator animator = Root.GetComponent<Animator>();
                animator.runtimeAnimatorController = null;
                animator.applyRootMotion = false;
                Rig = new Vrm10RuntimeControlRig(vrm.Humanoid, Root.transform);
                avatar = Rig.ControlRigAnimator.avatar;
                Require(avatar != null && avatar.isHuman && avatar.isValid, "Reference control rig is not Humanoid.");
                Handler = new HumanPoseHandler(avatar, Root.transform);
                Hips = Rig.GetBoneTransform(HumanBodyBones.Hips);
                HipsRest = Hips.localPosition;
            }
            public void Reset()
            {
                foreach (var bone in Rig.Bones.Values) bone.ControlBone.localRotation = Quaternion.identity;
                Hips.localPosition = HipsRest;
            }
            public void Dispose()
            {
                Handler.Dispose();
                Object.DestroyImmediate(Root);
                Object.DestroyImmediate(avatar);
            }
        }
    }
}
#endif

using System.Collections.Generic;
using UniVRM10;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>
    /// Presentation calibration for the two inspected bundled faces. Unknown
    /// models retain their authored VRM expression semantics. Vowels remain
    /// exclusively owned by speech; only lateral smile is budgeted around them.
    /// </summary>
    public sealed class AvatarFacialCalibration
    {
        private enum FaceKind { Authored, Joy, Matt }
        private FaceKind kind;
        private SkinnedMeshRenderer face;
        private AvatarVrmFacePresentation speechPresentation;
        private readonly float[] vowelContribution = new float[5];
        private float resolvedSpeechWeight;
        private readonly List<(int index, float original)> independent = new();
        private readonly Dictionary<string, int> channels = new();
        public bool IsCalibrated => kind != FaceKind.Authored;
        public bool IsJoy => kind == FaceKind.Joy;

        public void Bind(Transform root, Vrm10Instance vrm, bool bundledJoy,
            AvatarHumanoidFaceRestPose jaw, AvatarHumanoidSourceIdlePose source)
        {
            Clear();
            if (root == null) return;
            foreach (var renderer in root.GetComponentsInChildren<SkinnedMeshRenderer>(true))
            {
                Mesh mesh = renderer.sharedMesh;
                if (mesh == null) continue;
                // The mesh and source channel signature prevent coincidentally
                // named custom models from inheriting a built-in face profile.
                if (bundledJoy && vrm != null && mesh.vertexCount == 32930 &&
                    Has(mesh, "lip_smile.L", "lip_smile.R", "squint.L", "squint.R",
                        "blink_lower_up.L", "blink_lower_up.R", "AI", "U", "E", "O"))
                {
                    kind = FaceKind.Joy;
                    face = renderer;
                    speechPresentation = renderer.GetComponent<AvatarVrmFacePresentation>() ??
                        renderer.gameObject.AddComponent<AvatarVrmFacePresentation>();
                    CacheSpeechContributions(vrm);
                    CacheIndependent(vrm, "Smile_L", "Smile_R", "squint.L", "squint.R",
                        "blink_lower_up.L", "blink_lower_up.R");
                    return;
                }
                if (vrm == null && jaw != null && jaw.IsCaptured && source != null && source.IsCaptured &&
                    Has(mesh, "V_Open", "V_Wide", "V_Tight", "V_Tight_O", "V_Explosive", "V_Dental_Lip",
                        "Mouth_Smile_L", "Mouth_Smile_R", "Eye_Squint_L", "Eye_Squint_R"))
                {
                    kind = FaceKind.Matt;
                    face = renderer;
                    CacheIndependent(null, "Cheek_Raise_L", "Cheek_Raise_R");
                    return;
                }
            }
        }

        public static float SmileIntent(float happy, float mouthSmile, float love) =>
            Mathf.Clamp01(Mathf.Max(happy, mouthSmile, love * .55f));

        public float MouthSmile(float intent, float aa, float ih, float ou, float ee,
            float oh, float pp, float ff)
        {
            if (!IsCalibrated) return intent;
            // The source full-scale shapes are expressive extremes. Keep a
            // continuous light-to-broad range, without a permanent smile floor.
            float scale = IsJoy ? .72f : .62f;
            float articulation = Mathf.Max(aa * .48f, ih * .25f, ee * .35f,
                ou * .85f, oh * .78f, pp * .9f, ff * .55f);
            return Mathf.Clamp01(intent) * scale * (1f - Mathf.Clamp01(articulation));
        }

        public float EyeSmile(float intent) => IsCalibrated
            ? Mathf.SmoothStep(0f, 1f, Mathf.InverseLerp(.12f, 1f, intent)) : 0f;

        public float Surprise(float surprise, float smileIntent) => IsCalibrated
            ? surprise * (1f - Mathf.Clamp01(smileIntent) * .6f) : surprise;

        public void ApplyCompanions(float intent)
        {
            if (!IsCalibrated || face == null) return;
            float eyes = EyeSmile(intent);
            RefreshSpeechPresentation();
            if (IsJoy)
            {
                // Smile_L/R are exact duplicate deltas of lip_smile.L/R.
                // Happy owns those lips once; do not add the duplicate aliases.
                Write("Smile_L", 0f); Write("Smile_R", 0f);
                Write("squint.L", eyes * .20f); Write("squint.R", eyes * .20f);
                Write("blink_lower_up.L", eyes * .10f); Write("blink_lower_up.R", eyes * .10f);
            }
            else
            {
                Write("Cheek_Raise_L", eyes * .34f); Write("Cheek_Raise_R", eyes * .34f);
            }
        }

        public void SetSpeech(float aa, float ih, float ou, float ee, float oh)
        {
            resolvedSpeechWeight = aa * vowelContribution[0] + ih * vowelContribution[1] +
                ou * vowelContribution[2] + ee * vowelContribution[3] + oh * vowelContribution[4];
            RefreshSpeechPresentation();
        }

        private void RefreshSpeechPresentation()
        {
            if (IsJoy && speechPresentation != null)
                speechPresentation.SetSpeech(face, face.sharedMesh.GetBlendShapeIndex("AI"),
                    true, resolvedSpeechWeight);
        }

        private void CacheSpeechContributions(Vrm10Instance vrm)
        {
            var vowels = new[] { vrm.Vrm.Expression.Aa, vrm.Vrm.Expression.Ih,
                vrm.Vrm.Expression.Ou, vrm.Vrm.Expression.Ee, vrm.Vrm.Expression.Oh };
            int mouthIndex = face.sharedMesh.GetBlendShapeIndex("AI");
            for (int index = 0; index < vowels.Length; index++)
            {
                vowelContribution[index] = 0f;
                if (vowels[index]?.MorphTargetBindings == null) continue;
                foreach (var binding in vowels[index].MorphTargetBindings)
                {
                    if (binding.Index != mouthIndex) continue;
                    Transform target = string.IsNullOrEmpty(binding.RelativePath)
                        ? vrm.transform : vrm.transform.Find(binding.RelativePath);
                    if (target == face.transform) vowelContribution[index] += binding.Weight;
                }
            }
        }

        public void PresentSpeech() => speechPresentation?.Present();

        public void Clear()
        {
            speechPresentation?.Release();
            speechPresentation = null;
            resolvedSpeechWeight = 0f;
            if (face != null)
                foreach (var binding in independent)
                    face.SetBlendShapeWeight(binding.index, binding.original);
            independent.Clear(); channels.Clear(); face = null; kind = FaceKind.Authored;
        }

        private void CacheIndependent(Vrm10Instance vrm, params string[] names)
        {
            foreach (string name in names)
            {
                int index = face.sharedMesh.GetBlendShapeIndex(name);
                if (index < 0 || OwnedByExpression(vrm, index)) continue;
                channels.Add(name, index);
                independent.Add((index, face.GetBlendShapeWeight(index)));
            }
        }

        private bool OwnedByExpression(Vrm10Instance vrm, int index)
        {
            if (vrm == null) return false;
            foreach (var item in vrm.Vrm.Expression.Clips)
            {
                if (item.Clip?.MorphTargetBindings == null) continue;
                foreach (var binding in item.Clip.MorphTargetBindings)
                {
                    if (binding.Index != index) continue;
                    Transform target = string.IsNullOrEmpty(binding.RelativePath)
                        ? vrm.transform : vrm.transform.Find(binding.RelativePath);
                    if (target == face.transform) return true;
                }
            }
            return false;
        }

        private void Write(string name, float weight)
        {
            if (channels.TryGetValue(name, out int index))
                face.SetBlendShapeWeight(index, Mathf.Clamp01(weight) * 100f);
        }

        private static bool Has(Mesh mesh, params string[] names)
        {
            foreach (string name in names) if (mesh.GetBlendShapeIndex(name) < 0) return false;
            return true;
        }
    }
}

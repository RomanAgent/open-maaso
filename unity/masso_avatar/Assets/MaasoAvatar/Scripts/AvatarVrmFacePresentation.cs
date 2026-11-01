using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>
    /// Completes speech ownership after UniVRM's expression merger (11000).
    /// The inspected Joy surprise preset includes the AI vowel, so an emotion
    /// must not reopen a speech-owned silent/closed-lip frame. No expression
    /// definitions, materials, or third-party VRM bindings are changed.
    /// </summary>
    [DisallowMultipleComponent, DefaultExecutionOrder(12000)]
    public sealed class AvatarVrmFacePresentation : MonoBehaviour
    {
        private SkinnedMeshRenderer face;
        private int vowel = -1;
        private float speechWeight;
        private bool speechOwnsMouth;

        public void SetSpeech(SkinnedMeshRenderer renderer, int vowelIndex, bool ownsMouth, float weight)
        {
            face = renderer; vowel = vowelIndex;
            speechWeight = Mathf.Clamp01(weight); speechOwnsMouth = ownsMouth;
        }

        public void Release()
        {
            face = null; vowel = -1; speechWeight = 0f; speechOwnsMouth = false;
        }

        public void Present()
        {
            if (speechOwnsMouth && face != null && vowel >= 0)
                face.SetBlendShapeWeight(vowel, speechWeight * 100f);
        }

        private void LateUpdate() => Present();
        private void OnDisable() => Release();
    }
}

using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>Owns only Joy's inspected aperture morph after UniVRM's merge.
    /// Eye rotation, eyelids, speech and the authored mesh remain independent.</summary>
    [DisallowMultipleComponent, DefaultExecutionOrder(12010)]
    public sealed class AvatarPupilMorphPresentation : MonoBehaviour
    {
        public const float MaximumAddedMorphWeight = 12f;
        private SkinnedMeshRenderer eye;
        private int index = -1;
        private float originalWeight, dilation;

        public bool IsBound => eye != null && index >= 0;

        public void Bind(SkinnedMeshRenderer renderer, int shape)
        {
            Release();
            if (renderer == null || renderer.sharedMesh == null ||
                shape < 0 || shape >= renderer.sharedMesh.blendShapeCount) return;
            eye = renderer; index = shape;
            originalWeight = eye.GetBlendShapeWeight(index);
            dilation = 0f;
        }

        public void SetNormalized(float value)
        {
            dilation = float.IsNaN(value) || float.IsInfinity(value) ? 0f : Mathf.Clamp01(value);
            Present();
        }

        public void Present()
        {
            // A camera Receiver may retire after Unity destroys its avatar
            // child. C# ?. can still call this destroyed managed wrapper;
            // check Unity's object lifetime before any native Behaviour getter.
            if (this != null && IsBound && isActiveAndEnabled)
                eye.SetBlendShapeWeight(index, Mathf.Clamp(originalWeight +
                    MaximumAddedMorphWeight * dilation, 0f, 100f));
        }

        public void Release()
        {
            if (IsBound) eye.SetBlendShapeWeight(index, originalWeight);
            eye = null; index = -1; originalWeight = dilation = 0f;
        }

        private void LateUpdate() => Present();
        private void OnDisable()
        {
            // The world owner may suspend only the avatar child while its
            // camera Receiver and affect driver stay alive. Restore the source
            // aperture without retiring that binding; a later activation can
            // then present again. Explicit Release/Dispose still retires it.
            if (IsBound) eye.SetBlendShapeWeight(index, originalWeight);
        }
        private void OnDestroy() => Release();
    }
}

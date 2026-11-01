using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>Imported neutral jaw for non-VRM Humanoids. Body clips never own speech.</summary>
    public sealed class AvatarHumanoidFaceRestPose : MonoBehaviour
    {
        [SerializeField] private Transform jaw;
        [SerializeField] private Quaternion neutralRotation;
        [SerializeField] private Vector3 neutralPosition;
        [SerializeField] private Vector3 hingeAxis;
        [SerializeField] private bool captured;
        public bool IsCaptured => captured && jaw != null;

        // Authoring must call before any idle animation is sampled. A prefab
        // retains the imported rest, even if the Animator starts before binding.
        public void Capture(Animator animator)
        {
            if (animator == null || !animator.isHuman) return;
            jaw = animator.GetBoneTransform(HumanBodyBones.Jaw);
            if (jaw == null) return;
            neutralRotation = jaw.localRotation;
            neutralPosition = jaw.localPosition;
            hingeAxis = jaw.InverseTransformDirection(animator.transform.right).normalized;
            ConfigureImportedHinge();
            captured = true;
        }

        // Migrates an existing Matt prefab in memory and serializes the source
        // hinge on newly built prefabs. Other non-VRM Humanoids keep their
        // previously captured axis.
        public void ConfigureImportedHinge()
        {
            if (jaw != null && jaw.name == "CC_Base_JawRoot")
                hingeAxis = Vector3.forward;
        }

        public void Apply(float opening)
        {
            if (!IsCaptured) return;
            jaw.localPosition = neutralPosition;
            jaw.localRotation = neutralRotation * Quaternion.AngleAxis(
                Mathf.Clamp01(opening) * 12f, hingeAxis);
        }
    }
}

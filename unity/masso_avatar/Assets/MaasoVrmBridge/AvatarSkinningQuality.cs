using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>Keep an avatar's authored weights independent of mobile scene quality.</summary>
    public static class AvatarSkinningQuality
    {
        public static void Apply(Transform avatarRoot)
        {
            if (avatarRoot == null) return;
            foreach (SkinnedMeshRenderer renderer in
                avatarRoot.GetComponentsInChildren<SkinnedMeshRenderer>(true))
            {
                Mesh mesh = renderer.sharedMesh;
                if (mesh == null) continue;

                // VRM's four-weight meshes must not inherit Medium's two-bone
                // limit: clothing and skin lose different influences and separate.
                // Buffer layout remains available after CPU mesh data is released.
                switch (mesh.skinWeightBufferLayout)
                {
                    case SkinWeights.OneBone:
                    case SkinWeights.TwoBones:
                    case SkinWeights.FourBones:
                        renderer.quality = SkinQuality.Bone4;
                        break;
                    // Custom meshes with >4 influences retain their own policy;
                    // forcing Bone4 would downgrade an Auto/Unlimited setup.
                }
            }
        }
    }
}

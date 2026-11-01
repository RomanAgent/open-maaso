using UnityEngine;

namespace Maaso.World
{
    [CreateAssetMenu(
        fileName = "WorldEnvironmentProfile",
        menuName = "Maaso/World/Environment Profile")]
    public sealed class WorldEnvironmentProfile : ScriptableObject
    {
        [SerializeField] private AudioClip ambientClip;
        [SerializeField, Range(0f, 1f)] private float ambientVolume = 1f;
        [SerializeField, Range(0f, 1f)] private float speechDuckedVolume = 0.22f;
        [SerializeField, Min(0f)] private float speechDuckSeconds = 0.15f;
        [SerializeField, Min(0f)] private float windMain = 0.8f;
        [SerializeField, Min(0f)] private float windTurbulence = 0.25f;

        public AudioClip AmbientClip => ambientClip;
        public float AmbientVolume => ambientVolume;
        public float SpeechDuckedVolume => speechDuckedVolume;
        public float SpeechDuckSeconds => speechDuckSeconds;
        public float WindMain => windMain;
        public float WindTurbulence => windTurbulence;

        public void Configure(
            AudioClip clip,
            float volume,
            float duckedVolume,
            float duckSeconds,
            float mainWind,
            float turbulence)
        {
            ambientClip = clip;
            ambientVolume = Mathf.Clamp01(volume);
            speechDuckedVolume = Mathf.Clamp01(duckedVolume);
            speechDuckSeconds = Mathf.Max(0f, duckSeconds);
            windMain = Mathf.Max(0f, mainWind);
            windTurbulence = Mathf.Max(0f, turbulence);
        }
    }
}

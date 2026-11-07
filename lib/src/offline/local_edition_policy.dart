/// Uses the original Maaso application with local account/data adapters.
const bool kOpenMaasoLocalEdition = bool.fromEnvironment(
  'MAASO_OFFLINE_EDITION',
  defaultValue: true,
);

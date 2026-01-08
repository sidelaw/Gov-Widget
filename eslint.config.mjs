import DiscourseRecommendedTheme from "@discourse/lint-configs/eslint-theme";

export default [
  ...DiscourseRecommendedTheme,
  {
    languageOptions: {
      globals: {
        BigInt: "readonly",
      },
    },
    rules: {
      "no-console": "off", // Allow console statements for debugging
      "no-bitwise": "off", // Allow bitwise operators for hash calculations
    },
  },
];

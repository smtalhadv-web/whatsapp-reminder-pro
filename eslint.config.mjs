import tseslint from 'typescript-eslint';

export default tseslint.config(
  ...tseslint.configs.recommended,
  {
    files: ['**/*.ts', '**/*.tsx'],
    rules: {
      // Gradually replace legacy dashboard anys with concrete Supabase row types.
      '@typescript-eslint/no-explicit-any': 'off',
    },
  },
  {
    ignores: ['.next/**', 'node_modules/**', 'out/**', 'build/**'],
  },
);

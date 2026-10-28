/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ['./src/**/*.{ts,tsx}', './public/index.html'],
  theme: {
    extend: {
      colors: {
        // navy-lavender trung tính (phong cách 2026)
        ink: { 50: '#f4f3fb', 100: '#ebe9f6', 200: '#dcd9ee', 300: '#c3bfdc', 400: '#9a95b8', 500: '#706b92', 600: '#565176', 700: '#3e3a5c', 800: '#272446', 900: '#17153b' },
        brand: { 50: '#f1edff', 100: '#e4dcff', 200: '#cbbcff', 500: '#7b5cff', 600: '#6a45ff', 700: '#5633e6' },
        sun: '#ffcf3f', aqua: '#58b7ff', hot: '#ff5c7a', mint: '#22d3a0', nt: '#F07B3C',
      },
      boxShadow: { pop: '4px 4px 0 0 #17153b', 'pop-sm': '2px 2px 0 0 #17153b', soft: '0 8px 24px -12px rgba(23,21,59,.18)' },
      borderRadius: { '2xl': '1.1rem', '3xl': '1.6rem' },
    },
  },
  plugins: [],
};

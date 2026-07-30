/* ============================================================
   Veliroz CRM · Config global
   ============================================================
   La anon key es SEGURA de exponer (RLS es la barrera).
   La service_role NUNCA va acá.
   Firebase Auth: mismo proyecto que veliroz.com (checkout).
   ============================================================ */
window.VELIROZ_CRM = {
  supabase: {
    url:     "https://usfpzlxmmgruydqbymsx.supabase.co",
    anonKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVzZnB6bHhtbWdydXlkcWJ5bXN4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODUzNjcxODgsImV4cCI6MjEwMDk0MzE4OH0.pzlernBcJ1OC_mye-c8hGSFYm8l-veSB3URqCEtBWYc"
  },
  firebase: {
    apiKey: "AIzaSyBVE2LG5brCYxgeHcM9D_L1uhtS5j7v354",
    authDomain: "veliroz-9f23d.firebaseapp.com",
    projectId: "veliroz-9f23d",
    storageBucket: "veliroz-9f23d.firebasestorage.app",
    messagingSenderId: "634749264860",
    appId: "1:634749264860:web:b26a66bd60bc5ddf36a519",
    measurementId: "G-WD5N0LSGCZ"
  },
  bucket: "veliroz-evidencias",
  wa_novvx: "51950211475",     // Gabriel (Novvx)
  version: "v0.1.0"
};

{{flutter_js}}
{{flutter_build_config}}

// Render the app inside the iPhone frame defined in index.html.
_flutter.loader.load({
  config: {
    hostElement: document.getElementById('app-host'),
  },
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}},
  },
  onEntrypointLoaded: async function (engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine({
      hostElement: document.getElementById('app-host'),
    });
    await appRunner.runApp();
    document.body.classList.add('app-ready');
  },
});

@echo off
setlocal

REM Verifies that query-api OpenAPI contains /v1/aggregates/* routes.
set "ROOT=%~dp0.."
set "PY=%ROOT%\.venv\Scripts\python.exe"
set "URL=http://localhost:8002/openapi.json"

"%PY%" -c "import json,sys,urllib.request; url=r'%URL%';\
	o=json.load(urllib.request.urlopen(url,timeout=5));\
	paths=o.get('paths') or {};\
	agg=sorted([p for p in paths.keys() if p.startswith('/v1/aggregates/')]);\
	(print('NO aggregates routes found in OpenAPI') or sys.exit(2)) if not agg else (print('Aggregates routes in OpenAPI:') or [print('  '+p) for p in agg])"
exit /b %errorlevel%

endlocal

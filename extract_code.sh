cat slides.md | npx codedown sql | awk -v RS= -v ORS='\n\n' '!/\.\.\./' > code.sql

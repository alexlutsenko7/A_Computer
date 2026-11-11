# Generators for the Word documents in docs/

Needs Node.js with the `docx` npm package (`npm install docx` in a scratch folder, run from there).
Paper: US Letter, 1-inch margins.

    node keys_doc.js ../LSpectrum_Keys.docx
    python3 architecture_diagram.py ../../LSpectrum/ep4_ce15/rtl/osd_font.hex arch.png   # block diagram, Spectrum font
    node architecture_doc.js ../LSpectrum_Architecture.docx arch.png
    python3 connection_diagram.py ../../LSpectrum/ep4_ce15/rtl/osd_font.hex conn.png    # wiring overview
    node connection_doc.js ../LSpectrum_Connection.docx conn.png
    node l64_keys_doc.js ../L64_Keys.docx                                # machine menu + L64 keys and usage
    node ltari_keys_doc.js ../LTari_Keys.docx                              # LTari keys and usage
    python3 ltari_testplan.py ../LTari_Test_Plan.xlsx                      # LTari hardware test plan (openpyxl)
    node build_doc.js ../L_Build_and_Install.docx                         # building, the .jic, ESP32, SD card, ROMs
    node thirdparty_doc.js ../L_Third_Party.docx                          # external cores / libraries, licences, amounts

LSpectrum_FKeys.docx has no generator (export of a claude.ai doc); its F3 and F4 rows and the Ctrl+Alt+Del texts were edited in the .docx XML.

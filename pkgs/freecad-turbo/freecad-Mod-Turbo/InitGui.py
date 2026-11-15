import FreeCAD
import FreeCADGui


class TurboCamCommand:
    def GetResources(self):
        return {
            "MenuText": "1. FAO Turbo + Trace 3D (Rust SIMD)",
            "ToolTip": "Generer le parcours 2D/3D/5 axes, tracer la trajectoire 3D et exporter le G-Code",
        }

    def IsActive(self):
        return FreeCAD.ActiveDocument is not None

    def Activated(self):
        from PySide6 import QtWidgets
        import Part, FreeCADTurbo

        sel = FreeCADGui.Selection.getSelection()
        if not sel or not hasattr(sel[0], "Shape"):
            QtWidgets.QMessageBox.warning(
                None, "FreeCAD Turbo", "Selectionnez d'abord une piece 3D dans l'arbre ou la vue 3D."
            )
            return

        shape = sel[0].Shape
        doc = FreeCAD.ActiveDocument

        dlg = QtWidgets.QDialog()
        dlg.setWindowTitle("FreeCAD Turbo — FAO & Post-Processeur Rust SIMD")
        layout = QtWidgets.QFormLayout(dlg)

        cb_mode = QtWidgets.QComboBox()
        cb_mode.addItems(FreeCADTurbo.supported_modes())
        cb_mode.setCurrentText("SURFACE_5AXIS")

        cb_dialect = QtWidgets.QComboBox()
        cb_dialect.addItems(FreeCADTurbo.supported_dialects())
        cb_dialect.setCurrentText("SIEMENS_840D")

        sp_diam = QtWidgets.QDoubleSpinBox()
        sp_diam.setRange(0.1, 200.0)
        sp_diam.setValue(6.0)

        sp_step = QtWidgets.QDoubleSpinBox()
        sp_step.setRange(0.05, 50.0)
        sp_step.setValue(1.0)

        sp_down = QtWidgets.QDoubleSpinBox()
        sp_down.setRange(0.05, 50.0)
        sp_down.setValue(2.0)

        sp_feed = QtWidgets.QDoubleSpinBox()
        sp_feed.setRange(10.0, 50000.0)
        sp_feed.setValue(3000.0)

        layout.addRow("Strategie d'usinage :", cb_mode)
        layout.addRow("Directeur CNC (Post-Pro) :", cb_dialect)
        layout.addRow("Diametre outil (mm) :", sp_diam)
        layout.addRow("Pas radial / Stepover (mm) :", sp_step)
        layout.addRow("Pas axial / Stepdown (mm) :", sp_down)
        layout.addRow("Avance de coupe (mm/min) :", sp_feed)

        btns = QtWidgets.QDialogButtonBox(
            QtWidgets.QDialogButtonBox.Ok | QtWidgets.QDialogButtonBox.Cancel
        )
        btns.accepted.connect(dlg.accept)
        btns.rejected.connect(dlg.reject)
        layout.addWidget(btns)

        if dlg.exec() != QtWidgets.QDialog.Accepted:
            return

        gcode = FreeCADTurbo.generate_turbo_cnc_job(
            shape,
            mode=cb_mode.currentText(),
            dialect=cb_dialect.currentText(),
            linear_deflection=0.02,
            tool_diameter=sp_diam.value(),
            stepover=sp_step.value(),
            stepdown=sp_down.value(),
            feedrate=sp_feed.value(),
        )

        pts = []
        for line in gcode.splitlines():
            if line.startswith(("G0 ", "G1 ", "L ")):
                coords = {}
                for token in line.split()[1:]:
                    if token[0] in "XYZ" and len(token) > 1:
                        try:
                            coords[token[0]] = float(token[1:])
                        except ValueError:
                            pass
                if "X" in coords and "Y" in coords and "Z" in coords:
                    pts.append(FreeCAD.Vector(coords["X"], coords["Y"], coords["Z"]))

        if len(pts) > 1:
            path_obj = doc.addObject("Part::Feature", f"Trajectoire_{cb_mode.currentText()}")
            path_obj.Shape = Part.makePolygon(pts)
            path_obj.ViewObject.LineColor = (0.0, 1.0, 0.4)
            path_obj.ViewObject.LineWidth = 2.0
            doc.recompute()

        lines = gcode.splitlines()
        QtWidgets.QMessageBox.information(
            None,
            "G-Code & Trajectoire 3D Generes",
            f"Strategie : {cb_mode.currentText()} ({cb_dialect.currentText()})\n"
            f"Blocs G-Code generes : {len(lines)}\n"
            f"Points 3D traces : {len(pts)}\n\n"
            f"Apercu :\n" + "\n".join(lines[:8]),
        )


class TurboFemCommand:
    def GetResources(self):
        return {
            "MenuText": "2. Analyse FEM Rapide (PCG SIMD + CalculiX)",
            "ToolTip": "Calculer Fleche, Von Mises, Coef. Securite et 1ere Frequence propre sur la piece selectionnee",
        }

    def IsActive(self):
        return FreeCAD.ActiveDocument is not None

    def Activated(self):
        from PySide6 import QtWidgets
        import FreeCADTurbo

        sel = FreeCADGui.Selection.getSelection()
        if not sel or not hasattr(sel[0], "Shape"):
            QtWidgets.QMessageBox.warning(
                None, "FreeCAD Turbo FEM", "Selectionnez d'abord une piece 3D."
            )
            return

        force, ok = QtWidgets.QInputDialog.getDouble(
            None, "Charge appliquee (N)", "Effort total applique sur la piece (N) :", 2500.0, 1.0, 1e7, 1
        )
        if not ok:
            return

        res = FreeCADTurbo.run_turbo_fem(sel[0].Shape, mesh_size_mm=2.0, total_force_n=force)
        QtWidgets.QMessageBox.information(
            None,
            "Resultats Elements Finis (Rust PCG SIMD)",
            f"Noeuds : {res['node_count']} | Elements : {res['element_count']}\n"
            f"Iterations PCG : {res['solver_iterations']}\n"
            f"Fleche maximale : {res['max_displacement_mm']:.4f} mm\n"
            f"Contrainte Von Mises max : {res['max_von_mises_mpa']:.2f} MPa\n"
            f"Coefficient de securite (S355) : {res['safety_factor']:.2f}\n"
            f"1ere Frequence propre modale (f1) : {res['first_eigenfrequency_hz']:.1f} Hz",
        )


class TurboDispatchCommand:
    def GetResources(self):
        return {
            "MenuText": "3. Deleguer au Worker (Spool RAM / K3s)",
            "ToolTip": "Envoyer le calcul compresse en zstd dans /dev/shm/freecad-global-spool/queue",
        }

    def IsActive(self):
        return FreeCAD.ActiveDocument is not None

    def Activated(self):
        from PySide6 import QtWidgets
        import FreeCADTurbo

        sel = FreeCADGui.Selection.getSelection()
        if not sel or not hasattr(sel[0], "Shape"):
            QtWidgets.QMessageBox.warning(
                None, "FreeCAD Turbo Dispatch", "Selectionnez d'abord une piece 3D."
            )
            return

        job_id = FreeCADTurbo.dispatch_turbo_batch(sel[0].Shape)
        QtWidgets.QMessageBox.information(
            None,
            "Lot publie dans le Spool RAM",
            f"Job ID : {job_id}\nFile d'attente : /dev/shm/freecad-global-spool/queue/{job_id}.zst",
        )


class FreeCADTurboWorkbench(FreeCADGui.Workbench):
    MenuText = "FreeCAD Turbo (Rust SIMD)"
    ToolTip = "Atelier CFAO & FEM Haute Performance propulse par Rust SIMD, Rayon et Spool RAM"

    def Initialize(self):
        self.list = ["Turbo_CAM", "Turbo_FEM", "Turbo_Dispatch"]
        self.appendToolbar("FreeCAD Turbo", self.list)
        self.appendMenu("FreeCAD Turbo", self.list)


FreeCADGui.addCommand("Turbo_CAM", TurboCamCommand())
FreeCADGui.addCommand("Turbo_FEM", TurboFemCommand())
FreeCADGui.addCommand("Turbo_Dispatch", TurboDispatchCommand())
FreeCADGui.addWorkbench(FreeCADTurboWorkbench())

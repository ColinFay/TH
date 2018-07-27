library(shiny)
library(shinyBS) # Additional Bootstrap Controls
library(DT)
library(ggplot2)
library(plotly)
library(Cairo)
library(plyr)

options(shiny.reactlog = T, stringsAsFactors = FALSE)
rei = read.csv2('REI_TH.csv', header = TRUE, stringsAsFactors = FALSE, dec = ',')

# Seuil d'éligibilité
# 1417_1
grille_1417_1_CGI = read.csv2('limites_1417-1-CGI.csv', header = TRUE, 
                               stringsAsFactors = FALSE, dec = ',')
colnames(grille_1417_1_CGI) = c('Parts', 'Zone', 'Annee', 'Limite')

# 1417_1_bis
grille_1417_1bis_CGI = read.csv2('limites_1417-1bis-CGI.csv', header = TRUE, 
                               stringsAsFactors = FALSE, dec = ',')
colnames(grille_1417_1bis_CGI) = c('Parts', 'Zone', 'Annee', 'Limite')

# 1417-2
grille_1417_2_CGI = read.csv2('limites_1417-2-CGI.csv', header = TRUE, 
                              stringsAsFactors = FALSE, dec = ',')
colnames(grille_1417_2_CGI) = c('Parts', 'Zone', 'Annee', 'Limite')

# 1414-A1
grille_1414_A1_CGI = read.csv2('limites_1414-A-1-CGI.csv', header = TRUE, 
                              stringsAsFactors = FALSE, dec = ',')
colnames(grille_1414_A1_CGI) = c('Parts', 'Zone', 'Annee', 'Limite')



# Texte des tooltips
tooltip_PAC = "les enfants du contribuable ou ceux qu'il a recueillis, c'est-à-dire qui sont pris en compte dans le foyer fiscal pour le calcul de l'impôt sur le revenu au titre de l'année N-1 ;les ascendants du contribuable âgés de plus de 70 ans ou infirmes quel que soit leur âge, résidant avec le contribuable et remplissant la condition de revenus (montant de leur revenu fiscal de référence (RFR) de l’année précédente n’excédant pas la limite prévue à l’article 1417-I du CGI)"




######## FONCTION

# Afficher € après un montant
euro = function(montant){
  montant = paste(montant, '€')
  montant = gsub('^0 €$', '-', montant)
  return(montant)
}

# Seuils au titre de l'article 1417-I et  seuil_1417_1bis
calculer_seuil = function(grille, zone, annee, nombreParts){
  referentiel = subset(grille, Zone == zone & Annee == annee)
  
  partsSous3 = min(3, nombreParts)
  valeurPartsSous3 = subset(referentiel, Parts == partsSous3)$Limite
  partsAuDela3 = max(nombreParts - 3, 0)/0.5 # Décompte en demi-parts
  valeurDemiPart = subset(referentiel, Parts == 0.5)$Limite
  
  seuil = valeurPartsSous3 + partsAuDela3*valeurDemiPart
  return(seuil)
}

afficher_seuil = function(tableSeuils, zone, annee, nombreParts){
  seuil_exo = calculer_seuil(tableSeuils, zone, annee, nombreParts)
  phraseSeuil = sprintf("Dans votre département, le seuil d'exonération pour un foyer de %s parts est de %s€.", nombreParts, seuil_exo)
}

calculer_seuil(grille_1417_1_CGI, "Métropole", '2017', 3.25)
# Logement modeste dans les DOM 
exo_logement_modeste_DOM = function(zone, vlMoyenneCommune, vlBrute){
  return(zone != 'Métropole' & vlBrute <= round(0.4*vlMoyenneCommune))
}

# Multiplicateur
calculer_multiplicateur = function(nombrePAC, rfr, seuil, vlBrute, vlCommune, situation, alloc){
  general = 1
  PAC12 = min(2, nombrePAC)
  PAC3 = max(0, nombrePAC -2)
  special = (rfr <= seuil &  vlBrute <= 1.3 + nombrePAC*0.1*vlCommune) # Condition modeste + logement raisonnable
  handicape = 'Handicapé' %in% situation | 'ASI' %in% alloc |'AAH' %in% alloc
  multiplicateur = as.numeric(c(general, PAC12, PAC3, special, handicape))
  return(multiplicateur)
}

# Valeurs d'abattements pour une collectivité territoriale.

nomColAbattementsCommune = c('J51A', 'J31A', 'J41A', 'J61A', 'J61HA')
nomColAbattementsSyndicat = c('J52A', 'J32A', 'J42A', 'J62A', 'J62HA')
nomColAbattementsInterco = c('J53A', 'J33A', 'J43A', 'J63A', 'J63HA')
nomColAbattementsTSE = c('J51A', 'J31A', 'J41A', 'J61A', 'J61HA') # Les mêmes que commune

colTauxCotisations = list(commune = 'H12', 
                       syndicat = 'H22', 
                       interco = 'H32', 
                       TSE = c('H52', 'H52A'))
  
tauxGestion = list(commune = c(0.01, 0.03),
                   syndicat = c(0.08, 0.08),
                   interco = c(0.01, 0.03),
                   TSE = c(0.09,0.09),
                   GEMAPI = c(0.03, 0.03))

extraire_abattements = function(reiCommune, nomColAbattements){
  abattements = c()
  for (col in nomColAbattements){
    if (col %in% colnames(reiCommune)){
      abattements = c(abattements, reiCommune[, col])
    }else{
      abattements = c(abattements, 0)
    }
  }
  return(abattements)
}


calculer_frais = function(cotisation, typeRes, txGestion){
  tauxGestion = ifelse(typeRes == "secondaire", txGestion[2], txGestion[1])
  fraisGestion = cotisation*taux
  return(round(fraisGestion, 0))
}

calculer_cotisations = function(reiCommune, abattements, vlBrute, multiplicateur, nomtxCotis){
  vlNette = max(0,vlBrute - round(sum(abattements*multiplicateur),0))
  tauxCotis = sum(reiCommune[, nomtxCotis])
  cotisation = vlNette*tauxCotis/100
  return(round(cotisation, 0))
}

degrevement = function(rfr, zoneGeo, isf, nbParts){
  seuil = calculer_seuil(grille_1417_2_CGI, zoneGeo, 2017, nbParts)
  montant = ifelse(isf | rfr > seuil, 0, calculer_seuil(grille_1414_A1_CGI, zoneGeo, 2017, nbParts))
  return(montant)
}

taux_base_elevee = function(typeRes, vlNette){
  if (typeRes == 'principale' & vlNette > 4573){
    return(0.002)
  }
  if (typeRes == 'secondaire' & vlNette > 4573 & vlNette <= 7622){
    return(0.012)
  }
  if (typeRes == 'secondaire' & vlNette > 7622){
    return(0.017)
  }
  return(0)
}

taux_residence_secondaire = 0.015

detailler_calcul = function(reiCommune, vlBrute, typeRes, abattements, multiplicateur, 
                            nomtxCotis, txGestion, ct){
  vlNette = max(0,vlBrute - round(sum(abattements*multiplicateur),0))
  
  # Cotisation
  tauxCotis = sum(reiCommune[, nomtxCotis])
  cotisation = round(vlNette*tauxCotis/100,0)
  
  # Frais de gestion
  tauxGestion = ifelse(typeRes == "Secondaire", txGestion[2], txGestion[1])
  fraisGestion = round(cotisation*tauxGestion,0)
  
  # Prélèvement pour base elevée et Résidence secondaire
  tauxBaseElevee = ifelse(ct == 'commune', taux_base_elevee(typeRes, vlNette), 0)
  prelevementBaseElevee = round(vlNette*tauxBaseElevee,0)
  
  tauxResSecondaire = ifelse(ct %in% c('commune', 'interco') & typeRes == 'secondaire', 0.015, 0)
  prelèvementResSecondaire = round(vlNette*tauxResSecondaire,0)
  
  # Plafonnement
  
  detailCalcul = c(vlBrute, round(sum(abattements*multiplicateur),0), vlNette, 
                   paste0(tauxCotis, '%'), cotisation, 
                   paste0(100*tauxGestion, '%'), fraisGestion,
                   paste0(100*tauxBaseElevee, '%'), prelevementBaseElevee,
                   paste0(100*tauxResSecondaire, '%'), prelèvementResSecondaire)
  
  return(as.character(detailCalcul))
}


cascade_abattements = function(vlBrute, abattements, multiplicateur){
# 
  vlBrute = 1000
  abattements = c(0, 200, 400, 0, 0)
  multiplicateur = c(0,1,0,0,0)
  nom_abattements = c('GAB', 'PAC1-2', 'PAC3+', 'Special', 'Handicape')

  valeur = abattements*multiplicateur
  calcul = data.frame(
    etape = nom_abattements,
    abattements = abattements,
    multiplicateur = multiplicateur,
    valeur = valeur,
    start = c(vlBrute, vlBrute -cumsum(valeur[-length(valeur)])),
    end = c(vlBrute -cumsum(valeur)),
    type = 'abattement')
  
  calcul_net = calcul
  calcul_net$type = 'net'
  calcul_net$end = pmax(calcul_net$end, 0)
  calcul_net$start = 0

  calcul_vlb = data.frame(etape = 'VLB', start = 0, end = vlBrute, type = 'net')
  calcul_vln = data.frame(etape = 'VLN', start = 0, end = max(vlBrute-sum(valeur),0), type = 'net')
  
  calcul = rbind.fill(calcul_vlb, calcul, calcul_net, calcul_vln)
  calcul$etape = factor(calcul$etape,levels = unique(calcul$etape))
  calcul$id = as.numeric(calcul$etape)
  calcul$type = factor(calcul$type, levels = c('abattement','net'))

  # calcul$tooltip = NA
  calcul$text = ifelse(calcul$type == "abattement", 
                          paste(calcul$multiplicateur, 'x',calcul$abattements, '\n',
                                '=', calcul$valeur), 'aaaa')
  # Graphique
  g = ggplot(calcul, aes(etape, fill = type)) + 
    geom_rect(aes(x = etape, 
                  xmin = id - 0.45, xmax = id + 0.45, ymin = end, ymax = start)) +
    geom_segment(aes(x = id - 0.45, xend = id + 0.45, y = 0, yend = 0, colour=type)) 

  if (any(valeur>0)){
    g = g + geom_text(data=subset(calcul, type == 'abattement' & valeur >0),
                         aes(x=id,y=(start+end)/2,label=paste('-',start-end)))
  }

  g = ggplotly(g, tooltip = c('text'))
  g = hide_legend(g)
  return(g)
}